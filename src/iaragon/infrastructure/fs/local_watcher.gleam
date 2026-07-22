//// Turns local filesystem activity into reconciliation rounds. Events come
//// from filespy (real inotify events, when inotify-tools is installed) or
//// from polly (polling fallback, no external dependency) — both behind the
//// same NoticeLocalActivity command — and are debounced: a burst of writes
//// collapses into ONE ReconcileNow after a quiet period, so a big copy into
//// the mirror does not trigger a round per file.

import filespy
import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision.{type ChildSpecification}
import iaragon/application/reconciler
import polly
import simplifile

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

/// Whether the inotify backend can work here: filespy's `fs` application
/// shells out to inotifywait (inotify-tools) at runtime.
pub fn detect_inotify_support() -> Bool {
  find_executable("inotifywait")
}

@external(erlang, "iaragon_exec_ffi", "find_executable")
pub fn find_executable(name: String) -> Bool

/// Add the filesystem event source to the tree: real inotify events through
/// filespy when the machine supports it, the polly polling watcher
/// otherwise. Either way the source only pokes `notify` — the debounce and
/// the ReconcileNow stay in this module's actor.
pub fn add_watch_source(
  supervisor: static_supervisor.Builder,
  mirror_root: String,
  notify: Subject(Command),
  poll_interval_ms poll_interval_ms: Int,
  use_inotify use_inotify: Bool,
) -> static_supervisor.Builder {
  case use_inotify {
    True ->
      static_supervisor.add(
        supervisor,
        supervision.worker(fn() {
          // inotify refuses to watch a directory that does not exist yet.
          let _ = simplifile.create_directory_all(mirror_root)
          filespy.new()
          |> filespy.add_dir(mirror_root)
          |> filespy.set_handler(fn(_path, _event) {
            process.send(notify, NoticeLocalActivity)
          })
          |> filespy.start
        }),
      )
    False ->
      static_supervisor.add(
        supervisor,
        build_watch_options(mirror_root, notify, poll_interval_ms:)
          |> polly.supervised,
      )
  }
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
