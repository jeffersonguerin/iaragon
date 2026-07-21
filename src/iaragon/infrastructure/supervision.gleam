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
import iaragon/infrastructure/drive/backoff
import iaragon/infrastructure/drive/changes.{type Change}
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/transfer_pool
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

/// Start the whole tree. The composition root injects the persistence store
/// and the (authenticated) Drive port; remote changes are delivered to
/// `deliver_changes` — the reconciler's intake, once the pipeline lands.
pub fn start_daemon(
  store store: state_owner.StateStore,
  drive drive: remote_poller.DrivePort,
  deliver_changes deliver_changes: Subject(List(Change)),
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
      deliver: deliver_changes,
      poll_interval_ms: poll_interval_ms,
      pick_retry_delay_ms: fn(attempt) {
        backoff.compute_delay_ms(attempt, int.random(1000))
      },
    )

  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(state_owner.supervised(state_owner_name, store))
  |> static_supervisor.add(local_watcher.supervised(local_watcher_name))
  |> static_supervisor.add(remote_poller.supervised(
    remote_poller_name,
    poller_config,
  ))
  |> static_supervisor.add(reconciler.supervised(reconciler_name))
  |> static_supervisor.add(transfer_pool.supervised(transfer_pool_name))
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
