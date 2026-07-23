//// The daemon's supervision tree. OneForOne: each long-lived actor fails
//// independently — a remote poller crashing on a transient API error is
//// restarted alone, without taking the daemon down.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import iaragon/application/reconciler
import iaragon/application/state_owner
import iaragon/application/status_board
import iaragon/domain/entry
import iaragon/infrastructure/drive/backoff
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/transfer_pool
import iaragon/infrastructure/fs/hashing
import iaragon/infrastructure/fs/local_scan
import iaragon/infrastructure/fs/local_watcher
import iaragon/infrastructure/overlay/status_server

pub type Daemon {
  Daemon(
    supervisor: actor.Started(static_supervisor.Supervisor),
    state_owner: Subject(state_owner.Command),
    local_watcher: Subject(local_watcher.Command),
    remote_poller: Subject(remote_poller.Command),
    reconciler: Subject(reconciler.Command),
    transfer_pool: Subject(transfer_pool.Command),
    status_board: Subject(status_board.Command),
  )
}

const poll_interval_ms = 30_000

const round_interval_ms = 30_000

const watch_poll_interval_ms = 2000

const watch_debounce_ms = 1500

const status_call_timeout_ms = 500

/// YYYY-MM-DD in UTC, for conflicted-copy names.
fn build_date_stamp() -> String {
  let #(date, _time) =
    timestamp.to_calendar(timestamp.system_time(), calendar.utc_offset)
  int.to_string(date.year)
  <> "-"
  <> pad_two(calendar.month_to_int(date.month))
  <> "-"
  <> pad_two(date.day)
}

fn pad_two(value: Int) -> String {
  string.pad_start(int.to_string(value), 2, "0")
}

/// Start the whole tree. The composition root injects the persistence store,
/// the (authenticated) Drive port, the mirror location and the streaming
/// download. The pipeline is wired here: poller → reconciler →
/// transfer pool → state owner. Nothing syncs until someone sends the
/// first `Poll` (the composition root's decision).
pub fn start_daemon(
  store store: state_owner.StateStore,
  drive drive: remote_poller.DrivePort,
  mirror_root mirror_root: String,
  transfers transfers: transfer_pool.DriveTransferOps,
  native_policy native_policy: entry.NativeDocPolicy,
  signal_status signal_status: fn(String, entry.SyncStatus) -> Nil,
  status_socket_path status_socket_path: String,
) -> Result(Daemon, actor.StartError) {
  let state_owner_name = process.new_name(prefix: "state_owner")
  let local_watcher_name = process.new_name(prefix: "local_watcher")
  let remote_poller_name = process.new_name(prefix: "remote_poller")
  let reconciler_name = process.new_name(prefix: "reconciler")
  let transfer_pool_name = process.new_name(prefix: "transfer_pool")
  let status_board_name = process.new_name(prefix: "status_board")
  let status_board_subject = process.named_subject(status_board_name)

  let poller_config =
    remote_poller.PollerConfig(
      drive: drive,
      state_owner: process.named_subject(state_owner_name),
      deliver: process.named_subject(reconciler_name),
      poll_interval_ms: poll_interval_ms,
      pick_retry_delay_ms: fn(attempt) {
        backoff.compute_delay_ms(attempt, int.random(1000))
      },
    )
  let reconciler_subject = process.named_subject(reconciler_name)
  let transfer_config =
    transfer_pool.TransferConfig(
      root_dir: mirror_root,
      fetch_to_disk: transfers.fetch_to_disk,
      upload_to_drive: transfers.upload_to_drive,
      create_remote_folder: transfers.create_remote_folder,
      trash_remote: transfers.trash_remote,
      rename_remote: transfers.rename_remote,
      export_to_disk: transfers.export_to_disk,
      // Fan out: paint the emblem (gvfs) AND update the queryable board
      // (the Dolphin plugin's socket) in one signal.
      signal_status: fn(path, status) {
        signal_status(path, status)
        process.send(
          status_board_subject,
          status_board.MarkStatus(path, status),
        )
      },
      settle_upload: fn(path, outcome) {
        process.send(reconciler_subject, reconciler.SettleUpload(path, outcome))
      },
      settle_trash: fn(file_id, outcome) {
        process.send(
          reconciler_subject,
          reconciler.SettleTrash(file_id, outcome),
        )
      },
      settle_conflict: fn(path, outcome) {
        process.send(
          reconciler_subject,
          reconciler.SettleConflict(path, outcome),
        )
      },
      settle_move: fn(file_id, outcome) {
        process.send(
          reconciler_subject,
          reconciler.SettleMove(file_id, outcome),
        )
      },
      observe_folder: fn(sighting) {
        process.send(
          reconciler_subject,
          reconciler.ApplyRemoteChanges([reconciler.ObservedFile(sighting)]),
        )
      },
      state_owner: process.named_subject(state_owner_name),
      native_policy: native_policy,
      pick_retry_delay_ms: fn(attempt) {
        backoff.compute_delay_ms(attempt, int.random(1000))
      },
    )
  let transfer_pool_subject = process.named_subject(transfer_pool_name)
  let reconciler_config =
    reconciler.ReconcilerConfig(
      state_owner: process.named_subject(state_owner_name),
      dispatch_download: fn(remote) {
        process.send(
          transfer_pool_subject,
          transfer_pool.EnqueueDownload(remote),
        )
      },
      dispatch_delete_local: fn(known) {
        process.send(
          transfer_pool_subject,
          transfer_pool.EnqueueDeleteLocal(known),
        )
      },
      dispatch_upload: fn(plan) {
        process.send(transfer_pool_subject, transfer_pool.EnqueueUpload(plan))
      },
      dispatch_trash_remote: fn(file_id) {
        process.send(
          transfer_pool_subject,
          transfer_pool.EnqueueTrashRemote(file_id),
        )
      },
      dispatch_conflict_copy: fn(remote, copy_path) {
        process.send(
          transfer_pool_subject,
          transfer_pool.EnqueueConflictCopy(remote, copy_path),
        )
      },
      dispatch_move_local: fn(updated, from) {
        process.send(
          transfer_pool_subject,
          transfer_pool.EnqueueMoveLocal(updated, from),
        )
      },
      dispatch_move_remote: fn(plan) {
        process.send(
          transfer_pool_subject,
          transfer_pool.EnqueueMoveRemote(plan),
        )
      },
      request_seed: fn() {
        process.send(
          process.named_subject(remote_poller_name),
          remote_poller.Reseed,
        )
      },
      scan_local: fn() { local_scan.scan_mirror(mirror_root) },
      hash_local_file: fn(path) { hashing.hash_mirror_file(mirror_root, path) },
      native_policy: native_policy,
      round_interval_ms: round_interval_ms,
      today: build_date_stamp,
    )

  let watcher_config =
    local_watcher.WatcherConfig(
      deliver: reconciler_subject,
      debounce_ms: watch_debounce_ms,
    )

  let state_owner_subject = process.named_subject(state_owner_name)
  let board_config =
    status_board.BoardConfig(locate_known: fn(path) {
      process.call(
        state_owner_subject,
        status_call_timeout_ms,
        state_owner.FindKnownByPath(path, _),
      )
      != None
    })
  let answer_status = fn(line) {
    let prefix = mirror_root <> "/"
    case string.starts_with(line, prefix) {
      False -> "unknown"
      True -> {
        let path = string.drop_start(line, string.length(prefix))
        case
          process.call(
            status_board_subject,
            status_call_timeout_ms,
            status_board.FetchStatus(path, _),
          )
        {
          Some(entry.Syncing) -> "syncing"
          Some(entry.Synced) -> "synced"
          Some(entry.SyncFailed) -> "failed"
          None -> "unknown"
        }
      }
    }
  }

  static_supervisor.new(static_supervisor.OneForOne)
  // The default tolerance (2 restarts / 5 s) is far too tight for a tree
  // where a single state_owner hiccup can cascade a few dependent restarts:
  // one transient SQLite error under load could otherwise terminate the
  // whole daemon. Allow real recovery headroom.
  |> static_supervisor.restart_tolerance(intensity: 10, period: 30)
  |> static_supervisor.add(state_owner.supervised(state_owner_name, store))
  // The board must be registered before anything signals transfers to it.
  |> static_supervisor.add(status_board.supervised(
    status_board_name,
    board_config,
  ))
  |> static_supervisor.add(local_watcher.supervised(
    local_watcher_name,
    watcher_config,
  ))
  |> local_watcher.add_watch_source(
    mirror_root,
    process.named_subject(local_watcher_name),
    poll_interval_ms: watch_poll_interval_ms,
    use_inotify: local_watcher.detect_inotify_support(),
  )
  |> static_supervisor.add(remote_poller.supervised(
    remote_poller_name,
    poller_config,
  ))
  |> static_supervisor.add(reconciler.supervised(
    reconciler_name,
    reconciler_config,
  ))
  |> static_supervisor.add(transfer_pool.supervised(
    transfer_pool_name,
    transfer_config,
  ))
  |> static_supervisor.add(status_server.supervised(
    status_socket_path,
    answer_status,
  ))
  |> static_supervisor.start
  |> result.map(fn(supervisor) {
    Daemon(
      supervisor: supervisor,
      state_owner: process.named_subject(state_owner_name),
      local_watcher: process.named_subject(local_watcher_name),
      remote_poller: process.named_subject(remote_poller_name),
      reconciler: process.named_subject(reconciler_name),
      transfer_pool: process.named_subject(transfer_pool_name),
      status_board: status_board_subject,
    )
  })
}
