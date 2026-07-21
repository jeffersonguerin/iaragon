//// Shared test doubles: an ephemeral StateStore, a scripted-sequence fake
//// (each call consumes the next canned outcome; the last repeats forever),
//// and a polling assertion helper for cross-process effects.

import gleam/erlang/process.{type Subject}
import gleam/option.{None}
import gleam/otp/actor
import iaragon/application/state_owner

pub fn an_ephemeral_store() -> state_owner.StateStore {
  state_owner.StateStore(
    load_all_known: fn() { Ok([]) },
    load_page_token: fn() { Ok(None) },
    put_known: fn(_file) { Ok(Nil) },
    forget_known: fn(_file_id) { Ok(Nil) },
    save_page_token: fn(_token) { Ok(Nil) },
  )
}

pub fn start_ephemeral_state_owner() -> Subject(state_owner.Command) {
  let name = process.new_name(prefix: "fake_state_owner")
  let assert Ok(_started) = state_owner.start(name, an_ephemeral_store())
  process.named_subject(name)
}

type ScriptCommand(outcome) {
  PopNext(reply: Subject(outcome))
}

/// Build a fn that returns the scripted outcomes in order, one per call,
/// repeating the last one when the script runs dry.
pub fn script_outcomes(outcomes: List(outcome)) -> fn() -> outcome {
  let assert Ok(started) =
    actor.new(outcomes)
    |> actor.on_message(fn(remaining, command: ScriptCommand(outcome)) {
      let assert [current, ..rest] = remaining
      process.send(command.reply, current)
      case rest {
        [] -> actor.continue([current])
        rest -> actor.continue(rest)
      }
    })
    |> actor.start
  fn() { process.call(started.data, 1000, PopNext) }
}

/// Retry a cross-process assertion for up to attempts × 25 ms.
pub fn retry_until(attempts: Int, check: fn() -> Bool) -> Bool {
  case check() {
    True -> True
    False ->
      case attempts <= 1 {
        True -> False
        False -> {
          process.sleep(25)
          retry_until(attempts - 1, check)
        }
      }
  }
}
