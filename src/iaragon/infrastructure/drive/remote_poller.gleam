//// Polls the Drive Changes API and feeds remote deltas into the pipeline.
//// The very first poll bootstraps the persisted startPageToken (no history
//// is replayed); subsequent polls fetch every page, hand the changes to
//// `deliver`, and advance the token via the state owner — in that order, so
//// a crash between the two re-fetches changes instead of losing them.
////
//// Refusals (quota, transient errors) reschedule the poll with the injected
//// retry delay (truncated exponential backoff in production); successes
//// re-arm the regular polling interval. Isolated under the supervisor: a
//// crash restarts only this actor.

import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import iaragon/application/state_owner
import iaragon/infrastructure/drive/changes.{type Change}

pub type Command {
  Poll
}

/// What the poller needs from the Drive client, already composed with
/// authentication. Errors are strings: the poller only retries, it does not
/// interpret them.
pub type DrivePort {
  DrivePort(
    fetch_start_page_token: fn() -> Result(String, String),
    fetch_all_changes: fn(String) -> Result(#(List(Change), String), String),
  )
}

pub type PollerConfig {
  PollerConfig(
    drive: DrivePort,
    state_owner: Subject(state_owner.Command),
    deliver: Subject(List(Change)),
    poll_interval_ms: Int,
    pick_retry_delay_ms: fn(Int) -> Int,
  )
}

type State {
  State(config: PollerConfig, self: Subject(Command), failed_attempts: Int)
}

pub fn supervised(
  name: Name(Command),
  config: PollerConfig,
) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name, config) })
}

pub fn start(
  name: Name(Command),
  config: PollerConfig,
) -> actor.StartResult(Subject(Command)) {
  actor.new(State(
    config: config,
    self: process.named_subject(name),
    failed_attempts: 0,
  ))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  case command {
    Poll -> {
      let config = state.config
      let outcome = case
        process.call(config.state_owner, 5000, state_owner.GetPageToken)
      {
        None -> bootstrap_page_token(config)
        Some(page_token) -> advance_changes(config, page_token)
      }
      case outcome {
        Ok(Nil) -> {
          process.send_after(state.self, config.poll_interval_ms, Poll)
          actor.continue(State(..state, failed_attempts: 0))
        }
        Error(_reason) -> {
          let delay = config.pick_retry_delay_ms(state.failed_attempts)
          process.send_after(state.self, delay, Poll)
          actor.continue(
            State(..state, failed_attempts: state.failed_attempts + 1),
          )
        }
      }
    }
  }
}

fn bootstrap_page_token(config: PollerConfig) -> Result(Nil, String) {
  case config.drive.fetch_start_page_token() {
    Ok(token) -> {
      process.send(config.state_owner, state_owner.SetPageToken(token))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

fn advance_changes(
  config: PollerConfig,
  page_token: String,
) -> Result(Nil, String) {
  case config.drive.fetch_all_changes(page_token) {
    Ok(#(changes, fresh_token)) -> {
      case changes {
        [] -> Nil
        changes -> process.send(config.deliver, changes)
      }
      process.send(config.state_owner, state_owner.SetPageToken(fresh_token))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}
