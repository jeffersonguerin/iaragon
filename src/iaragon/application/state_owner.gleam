//// Owner of the "last known synced state": the fileId ↔ path mapping with
//// the metadata snapshot of the last sync, plus the Changes API page token.
//// Reads are served from an in-memory cache; every mutation is written
//// through the injected `StateStore` port (SQLite in production, fakes in
//// tests — application code never imports concrete infrastructure).
////
//// A failing store crashes the actor on purpose: the supervisor restarts it
//// and the fresh actor reloads the cache from the store.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import iaragon/domain/entry.{type KnownFile}

pub type Command {
  PutKnown(file: KnownFile)
  GetKnown(file_id: String, reply: Subject(Option(KnownFile)))
  ListKnown(reply: Subject(List(KnownFile)))
  ForgetKnown(file_id: String)
  SetPageToken(token: String)
  GetPageToken(reply: Subject(Option(String)))
}

/// The persistence port. Implementations map their own error type to a
/// String; the actor treats any Error as fatal (let it crash).
pub type StateStore {
  StateStore(
    load_all_known: fn() -> Result(List(KnownFile), String),
    load_page_token: fn() -> Result(Option(String), String),
    put_known: fn(KnownFile) -> Result(Nil, String),
    forget_known: fn(String) -> Result(Nil, String),
    save_page_token: fn(String) -> Result(Nil, String),
  )
}

type State {
  State(
    store: StateStore,
    known_by_id: Dict(String, KnownFile),
    page_token: Option(String),
  )
}

pub fn supervised(
  name: Name(Command),
  store: StateStore,
) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name, store) })
}

pub fn start(
  name: Name(Command),
  store: StateStore,
) -> actor.StartResult(Subject(Command)) {
  let assert Ok(known) = store.load_all_known()
  let assert Ok(page_token) = store.load_page_token()
  let known_by_id =
    known
    |> list.map(fn(file) { #(file.file_id, file) })
    |> dict.from_list

  actor.new(State(store:, known_by_id:, page_token:))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  case command {
    PutKnown(file) -> {
      let assert Ok(Nil) = state.store.put_known(file)
      actor.continue(
        State(
          ..state,
          known_by_id: dict.insert(state.known_by_id, file.file_id, file),
        ),
      )
    }
    GetKnown(file_id, reply) -> {
      process.send(
        reply,
        option.from_result(dict.get(state.known_by_id, file_id)),
      )
      actor.continue(state)
    }
    ListKnown(reply) -> {
      process.send(reply, dict.values(state.known_by_id))
      actor.continue(state)
    }
    ForgetKnown(file_id) -> {
      let assert Ok(Nil) = state.store.forget_known(file_id)
      actor.continue(
        State(..state, known_by_id: dict.delete(state.known_by_id, file_id)),
      )
    }
    SetPageToken(token) -> {
      let assert Ok(Nil) = state.store.save_page_token(token)
      actor.continue(State(..state, page_token: Some(token)))
    }
    GetPageToken(reply) -> {
      process.send(reply, state.page_token)
      actor.continue(state)
    }
  }
}
