import gleam/erlang/process.{type Subject}
import gleam/otp/static_supervisor
import iaragon/application/reconciler
import iaragon/infrastructure/fs/local_watcher.{WatcherConfig}
import polly
import simplifile

// The watcher turns filesystem noise into reconciliation rounds: bursts of
// activity collapse into ONE ReconcileNow after a quiet period, and polly
// (polling watcher, no inotify dependency) feeds it real events.

fn start_watcher(
  deliver: Subject(reconciler.Command),
  debounce_ms: Int,
) -> Subject(local_watcher.Command) {
  let name = process.new_name(prefix: "watcher_test")
  let assert Ok(_) =
    local_watcher.start(
      name,
      WatcherConfig(deliver: deliver, debounce_ms: debounce_ms),
    )
  process.named_subject(name)
}

pub fn activity_triggers_a_round_after_the_quiet_period_test() {
  let deliver = process.new_subject()
  let watcher = start_watcher(deliver, 25)

  process.send(watcher, local_watcher.NoticeLocalActivity)

  assert process.receive(deliver, 1000) == Ok(reconciler.ReconcileNow)
}

pub fn a_burst_of_activity_collapses_into_one_round_test() {
  let deliver = process.new_subject()
  let watcher = start_watcher(deliver, 50)

  process.send(watcher, local_watcher.NoticeLocalActivity)
  process.send(watcher, local_watcher.NoticeLocalActivity)
  process.send(watcher, local_watcher.NoticeLocalActivity)
  process.send(watcher, local_watcher.NoticeLocalActivity)

  assert process.receive(deliver, 1000) == Ok(reconciler.ReconcileNow)
  assert process.receive(deliver, 200) == Error(Nil)
}

pub fn activity_after_a_flush_triggers_again_test() {
  let deliver = process.new_subject()
  let watcher = start_watcher(deliver, 25)

  process.send(watcher, local_watcher.NoticeLocalActivity)
  assert process.receive(deliver, 1000) == Ok(reconciler.ReconcileNow)

  process.send(watcher, local_watcher.NoticeLocalActivity)
  assert process.receive(deliver, 1000) == Ok(reconciler.ReconcileNow)
}

pub fn filesystem_changes_flow_through_polly_test() {
  let root = "build/test-scratch/local_watcher/polly"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let deliver = process.new_subject()
  let watcher = start_watcher(deliver, 25)

  let assert Ok(_polly) =
    local_watcher.build_watch_options(root, watcher, poll_interval_ms: 25)
    |> polly.watch

  let assert Ok(Nil) =
    simplifile.write(to: root <> "/fresh.txt", contents: "hello")

  assert process.receive(deliver, 3000) == Ok(reconciler.ReconcileNow)
}

// --- Backend selection ----------------------------------------------------------

pub fn executables_are_located_on_the_path_test() {
  assert local_watcher.find_executable("sh") == True
  assert local_watcher.find_executable("no-such-tool-iaragon") == False
}

pub fn the_polling_source_feeds_the_watcher_through_the_tree_test() {
  let root = "build/test-scratch/local_watcher/source-polly"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let deliver = process.new_subject()
  let watcher = start_watcher(deliver, 25)

  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> local_watcher.add_watch_source(
      root,
      watcher,
      poll_interval_ms: 25,
      use_inotify: False,
    )
    |> static_supervisor.start

  let assert Ok(Nil) =
    simplifile.write(to: root <> "/fresh.txt", contents: "hello")

  assert process.receive(deliver, 3000) == Ok(reconciler.ReconcileNow)
}

pub fn the_inotify_source_feeds_the_watcher_through_the_tree_test() {
  case local_watcher.detect_inotify_support() {
    // Without inotify-tools the daemon runs on the polly fallback anyway;
    // there is no inotify path to exercise on this machine.
    False -> Nil
    True -> {
      let root = "build/test-scratch/local_watcher/source-inotify"
      let assert Ok(Nil) = simplifile.create_directory_all(root)
      let deliver = process.new_subject()
      let watcher = start_watcher(deliver, 25)

      let assert Ok(_) =
        static_supervisor.new(static_supervisor.OneForOne)
        |> local_watcher.add_watch_source(
          root,
          watcher,
          // An hour: an event arriving fast proves it came from inotify,
          // not from a poll.
          poll_interval_ms: 3_600_000,
          use_inotify: True,
        )
        |> static_supervisor.start

      // Give inotifywait a moment to set up its watches.
      process.sleep(500)
      let assert Ok(Nil) =
        simplifile.write(to: root <> "/fresh.txt", contents: "hello")

      assert process.receive(deliver, 5000) == Ok(reconciler.ReconcileNow)
      Nil
    }
  }
}

pub fn a_flush_with_no_reconciler_registered_does_not_crash_the_watcher_test() {
  // The reconciler restarting is routine; a raw send to its unregistered
  // name RAISES in the sender, and a crashing watcher would burn two more
  // slots of the supervisor's restart budget for one transient fault.
  let ghost_name: process.Name(reconciler.Command) =
    process.new_name(prefix: "never_registered_reconciler")
  let watcher = start_watcher(process.named_subject(ghost_name), 10)

  process.send(watcher, local_watcher.NoticeLocalActivity)
  process.sleep(60)

  // Still alive and still answering.
  assert process.subject_owner(watcher) != Error(Nil)
  process.send(watcher, local_watcher.NoticeLocalActivity)
  process.sleep(60)
  assert process.subject_owner(watcher) != Error(Nil)
}
