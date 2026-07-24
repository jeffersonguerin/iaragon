import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import iaragon/application/status_board
import iaragon/domain/entry.{SyncFailed, Synced, Syncing}

// The status board answers "what is the sync state of this path?" for
// presentation adapters (the Dolphin plugin's socket server). Transfers
// this run live in its own dict; anything untouched falls back to the
// known index — a file synced in an earlier run is still synced.

fn start_board(
  locate_known: fn(String) -> Bool,
) -> Subject(status_board.Command) {
  let name = process.new_name(prefix: "status_board_test")
  let assert Ok(_) =
    status_board.start(name, status_board.BoardConfig(locate_known:))
  process.named_subject(name)
}

pub fn a_marked_path_reports_its_latest_status_test() {
  let board = start_board(fn(_path) { False })

  process.send(board, status_board.MarkStatus("docs/report.txt", Syncing))
  assert process.call(board, 500, status_board.FetchStatus("docs/report.txt", _))
    == Some(Syncing)

  process.send(board, status_board.MarkStatus("docs/report.txt", Synced))
  assert process.call(board, 500, status_board.FetchStatus("docs/report.txt", _))
    == Some(Synced)
}

pub fn an_untouched_known_path_is_synced_test() {
  let board = start_board(fn(path) { path == "docs/old.txt" })

  assert process.call(board, 500, status_board.FetchStatus("docs/old.txt", _))
    == Some(Synced)
}

pub fn a_stranger_path_has_no_status_test() {
  let board = start_board(fn(_path) { False })

  assert process.call(board, 500, status_board.FetchStatus("stranger.txt", _))
    == None
}

pub fn transient_state_wins_over_the_known_index_test() {
  // The file is in the known index AND being re-uploaded right now: the
  // in-flight status is the truthful one.
  let board = start_board(fn(_path) { True })

  process.send(board, status_board.MarkStatus("docs/report.txt", Syncing))
  assert process.call(board, 500, status_board.FetchStatus("docs/report.txt", _))
    == Some(Syncing)
}

// --- overall (aggregate) status: the tray's one-glance signal ------------

pub fn overall_is_synced_when_idle_test() {
  // Nothing in flight, nothing failed: the daemon is at rest and healthy.
  let board = start_board(fn(_path) { False })

  assert process.call(board, 500, status_board.FetchOverall) == Synced
}

pub fn overall_is_syncing_when_any_path_syncing_test() {
  let board = start_board(fn(_path) { False })

  process.send(board, status_board.MarkStatus("a.txt", Synced))
  process.send(board, status_board.MarkStatus("b.txt", Syncing))
  assert process.call(board, 500, status_board.FetchOverall) == Syncing
}

pub fn overall_is_failed_when_a_path_failed_and_none_syncing_test() {
  let board = start_board(fn(_path) { False })

  process.send(board, status_board.MarkStatus("a.txt", Synced))
  process.send(board, status_board.MarkStatus("b.txt", SyncFailed))
  assert process.call(board, 500, status_board.FetchOverall) == SyncFailed
}

pub fn overall_prefers_syncing_over_failed_test() {
  // Work in flight is the headline even if something else has failed.
  let board = start_board(fn(_path) { False })

  process.send(board, status_board.MarkStatus("a.txt", SyncFailed))
  process.send(board, status_board.MarkStatus("b.txt", Syncing))
  assert process.call(board, 500, status_board.FetchOverall) == Syncing
}
