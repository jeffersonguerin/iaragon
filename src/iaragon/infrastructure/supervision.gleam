//// The daemon's supervision tree. OneForOne: each long-lived actor fails
//// independently — a remote poller crashing on a transient API error is
//// restarted alone, without taking the daemon down.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import iaragon/application/reconciler
import iaragon/application/state_owner
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

/// Start the whole tree. Actors are registered under fresh names so their
/// subjects survive a supervisor-driven restart of the underlying process.
/// The state store is injected by the composition root (SQLite in
/// production, fakes in tests).
pub fn start_daemon(
  store store: state_owner.StateStore,
) -> Result(Daemon, actor.StartError) {
  let state_owner_name = process.new_name(prefix: "state_owner")
  let local_watcher_name = process.new_name(prefix: "local_watcher")
  let remote_poller_name = process.new_name(prefix: "remote_poller")
  let reconciler_name = process.new_name(prefix: "reconciler")
  let transfer_pool_name = process.new_name(prefix: "transfer_pool")

  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(state_owner.supervised(state_owner_name, store))
  |> static_supervisor.add(local_watcher.supervised(local_watcher_name))
  |> static_supervisor.add(remote_poller.supervised(remote_poller_name))
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
