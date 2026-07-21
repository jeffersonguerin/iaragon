//// Owner of the "last known synced state": the fileId ↔ path mapping with
//// the metadata snapshot of the last sync, plus the Changes API page token.
//// In-memory for now; SQLite persistence will arrive as an infrastructure
//// adapter behind this same message contract.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import iaragon/domain/entry.{type KnownFile}

pub type Command {
  PutKnown(file: KnownFile)
  GetKnown(file_id: String, reply: Subject(Option(KnownFile)))
  ForgetKnown(file_id: String)
  SetPageToken(token: String)
  GetPageToken(reply: Subject(Option(String)))
}

type State {
  State(known_by_id: Dict(String, KnownFile), page_token: Option(String))
}

pub fn supervised(name: Name(Command)) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name) })
}

pub fn start(name: Name(Command)) -> actor.StartResult(Subject(Command)) {
  actor.new(State(known_by_id: dict.new(), page_token: None))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  case command {
    PutKnown(file) ->
      actor.continue(
        State(
          ..state,
          known_by_id: dict.insert(state.known_by_id, file.file_id, file),
        ),
      )
    GetKnown(file_id, reply) -> {
      process.send(
        reply,
        option.from_result(dict.get(state.known_by_id, file_id)),
      )
      actor.continue(state)
    }
    ForgetKnown(file_id) ->
      actor.continue(
        State(..state, known_by_id: dict.delete(state.known_by_id, file_id)),
      )
    SetPageToken(token) ->
      actor.continue(State(..state, page_token: Some(token)))
    GetPageToken(reply) -> {
      process.send(reply, state.page_token)
      actor.continue(state)
    }
  }
}
