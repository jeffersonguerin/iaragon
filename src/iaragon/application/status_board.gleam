//// Answers "what is the sync state of this path?" for presentation
//// adapters (the file-manager status socket). Transfers of THIS run are
//// tracked in memory as the pool signals them; any untouched path falls
//// back to the known index through an injected lookup — a file synced in
//// an earlier run is still synced. Pure application logic: no sockets, no
//// gio, no Drive.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import iaragon/domain/entry.{type SyncStatus, SyncFailed, Synced, Syncing}

pub type Command {
  MarkStatus(path: String, status: SyncStatus)
  FetchStatus(path: String, reply: Subject(Option(SyncStatus)))
  /// The one-glance aggregate for a tray/status indicator: `Syncing` if any
  /// path is in flight, else `SyncFailed` if any path is failing, else
  /// `Synced` (idle-and-healthy — the empty board included).
  FetchOverall(reply: Subject(SyncStatus))
}

pub type BoardConfig {
  BoardConfig(
    /// Whether the known index holds a file at this mirror path.
    locate_known: fn(String) -> Bool,
  )
}

type State {
  State(config: BoardConfig, statuses: Dict(String, SyncStatus))
}

pub fn supervised(
  name: Name(Command),
  config: BoardConfig,
) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name, config) })
}

pub fn start(
  name: Name(Command),
  config: BoardConfig,
) -> actor.StartResult(Subject(Command)) {
  actor.new(State(config: config, statuses: dict.new()))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  case command {
    MarkStatus(path, status) ->
      actor.continue(
        State(..state, statuses: dict.insert(state.statuses, path, status)),
      )
    FetchStatus(path, reply) -> {
      let status = case dict.get(state.statuses, path) {
        // In-flight state is fresher than the index: a known file being
        // re-uploaded is syncing, not synced.
        Ok(status) -> Some(status)
        Error(Nil) ->
          case state.config.locate_known(path) {
            True -> Some(Synced)
            False -> None
          }
      }
      process.send(reply, status)
      actor.continue(state)
    }
    FetchOverall(reply) -> {
      process.send(reply, summarize(state.statuses))
      actor.continue(state)
    }
  }
}

/// Priority fold over the in-flight statuses: work in flight is the headline,
/// then a failure, else at rest. An empty board is `Synced` — nothing wrong.
fn summarize(statuses: Dict(String, SyncStatus)) -> SyncStatus {
  let values = dict.values(statuses)
  case list.any(values, fn(s) { s == Syncing }) {
    True -> Syncing
    False ->
      case list.any(values, fn(s) { s == SyncFailed }) {
        True -> SyncFailed
        False -> Synced
      }
  }
}
