import gleam/erlang/process.{type Subject}
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
