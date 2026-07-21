//// The daemon's supervision tree. OneForOne: each long-lived actor fails
//// independently — a remote poller crashing on a transient API error is
//// restarted alone, without taking the daemon down.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import iaragon/application/reconciler
import iaragon/application/state_owner
import iaragon/domain/entry
import iaragon/infrastructure/drive/backoff
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/transfer_pool
import iaragon/infrastructure/fs/hashing
import iaragon/infrastructure/fs/local_scan
import iaragon/infrastructure/fs/local_watcher

pub type Daemon {
  Daemon(
    supervisor: actor.Started(static_supervisor.Supervisor),
    state_owner: Subject(state_owner.Command),
    local_watcher: Subject(local_watcher.Command),
    remote_poller: Subject(remote_poller.Command),
    reconciler: Subject(reconciler.Command),
    transfer_pool: Subject(transfer_pool.Command),
  )
}

const poll_interval_ms = 30_000

/// Start the whole tree. The composition root injects the persistence store,
/// the (authenticated) Drive port, the mirror location and the streaming
/// download. The pipeline is wired here: poller → reconciler →
/// transfer pool → state owner. Nothing syncs until someone sends the
/// first `Poll` (the composition root's decision).
pub fn start_daemon(
  store store: state_owner.StateStore,
  drive drive: remote_poller.DrivePort,
  mirror_root mirror_root: String,
  fetch_to_disk fetch_to_disk: fn(String, String) -> Result(Nil, String),
  native_policy native_policy: entry.NativeDocPolicy,
) -> Result(Daemon, actor.StartError) {
  let state_owner_name = process.new_name(prefix: "state_owner")
  let local_watcher_name = process.new_name(prefix: "local_watcher")
  let remote_poller_name = process.new_name(prefix: "remote_poller")
  let reconciler_name = process.new_name(prefix: "reconciler")
  let transfer_pool_name = process.new_name(prefix: "transfer_pool")

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
  let transfer_config =
    transfer_pool.TransferConfig(
      root_dir: mirror_root,
      fetch_to_disk: fetch_to_disk,
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
      dispatch_delete_local: fn(file_id, path) {
        process.send(
          transfer_pool_subject,
          transfer_pool.EnqueueDeleteLocal(file_id, path),
        )
      },
      scan_local: fn() { local_scan.scan_mirror(mirror_root) },
      hash_local_file: fn(path) { hashing.hash_mirror_file(mirror_root, path) },
      native_policy: native_policy,
    )

  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(state_owner.supervised(state_owner_name, store))
  |> static_supervisor.add(local_watcher.supervised(local_watcher_name))
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
  |> static_supervisor.start
  |> result.map(fn(supervisor) {
    Daemon(
      supervisor: supervisor,
      state_owner: process.named_subject(state_owner_name),
      local_watcher: process.named_subject(local_watcher_name),
      remote_poller: process.named_subject(remote_poller_name),
      reconciler: process.named_subject(reconciler_name),
      transfer_pool: process.named_subject(transfer_pool_name),
    )
  })
}
