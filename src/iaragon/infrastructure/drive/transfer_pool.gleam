//// Pool of transfer workers executing the reconciler's decisions: downloads
//// (`files/{id}?alt=media`), uploads (resumable, 256 KB-multiple chunks) and
//// deletions, with exponential backoff on quota errors.
//// Stub for now: only proves liveness under supervision; `Ping` is
//// scaffolding until the real commands land.

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}

pub type Command {
  Ping(reply: Subject(Nil))
}

pub fn supervised(name: Name(Command)) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name) })
}

pub fn start(name: Name(Command)) -> actor.StartResult(Subject(Command)) {
  actor.new(Nil)
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(state: Nil, command: Command) -> actor.Next(Nil, Command) {
  case command {
    Ping(reply) -> {
      process.send(reply, Nil)
      actor.continue(state)
    }
  }
}
