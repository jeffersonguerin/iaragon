//// Turns local filesystem activity into reconciliation rounds. Events come
//// from polly (a polling watcher — no inotify-tools dependency; filespy can
//// slot in later behind the same command) and are debounced: a burst of
//// writes collapses into ONE ReconcileNow after a quiet period, so a big
//// copy into the mirror does not trigger a round per file.

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import iaragon/application/reconciler
import polly

pub type Command {
  /// Something changed under the mirror root.
  NoticeLocalActivity
  /// Internal: the quiet period ended.
  FlushActivity
}

pub type WatcherConfig {
  WatcherConfig(deliver: Subject(reconciler.Command), debounce_ms: Int)
}

type State {
  State(config: WatcherConfig, self: Subject(Command), flush_scheduled: Bool)
}

pub fn supervised(
  name: Name(Command),
  config: WatcherConfig,
) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name, config) })
}

pub fn start(
  name: Name(Command),
  config: WatcherConfig,
) -> actor.StartResult(Subject(Command)) {
  actor.new(State(
    config: config,
    self: process.named_subject(name),
    flush_scheduled: False,
  ))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

/// Polly options watching the mirror root, delivering (debounced through the
/// watcher actor) into reconciliation. The composition root wraps this in
/// `polly.supervised`; tests call `polly.watch` directly.
pub fn build_watch_options(
  mirror_root: String,
  notify: Subject(Command),
  poll_interval_ms poll_interval_ms: Int,
) -> polly.Options {
  polly.new()
  |> polly.add_dir(mirror_root)
  |> polly.interval(poll_interval_ms)
  |> polly.ignore_initial_missing
  |> polly.add_callback(fn(_event) { process.send(notify, NoticeLocalActivity) })
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  case command {
    NoticeLocalActivity ->
      case state.flush_scheduled {
        True -> actor.continue(state)
        False -> {
          process.send_after(
            state.self,
            state.config.debounce_ms,
            FlushActivity,
          )
          actor.continue(State(..state, flush_scheduled: True))
        }
      }
    FlushActivity -> {
      process.send(state.config.deliver, reconciler.ReconcileNow)
      actor.continue(State(..state, flush_scheduled: False))
    }
  }
}
