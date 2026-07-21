//// Polls the Drive Changes API and feeds the reconciler. The FIRST
//// successful cycle always seeds the mirror (real root id + full listing):
//// the reconciler's remote model lives in memory and does not survive
//// restarts, and the very first run has no history at all. Cycle order is
//// deliberate — start page token before the snapshot, so changes that land
//// mid-listing are replayed afterwards (idempotent) instead of lost.
////
//// After seeding: fetch every page, deliver the observations BEFORE
//// advancing the token (a crash in between re-fetches instead of losing
//// changes), retry refusals with the injected delay, re-arm the polling
//// interval on success. Drive wire types are translated here into the
//// application's contract — application code never imports this module.

import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import iaragon/application/reconciler.{
  type RemoteObservation, type RemoteSighting,
}
import iaragon/application/state_owner
import iaragon/infrastructure/drive/changes.{type Change, type ChangedFile}

pub type Command {
  Poll
}

/// What the poller needs from the Drive client, already composed with
/// authentication. Errors are strings: the poller only retries, it does not
/// interpret them.
pub type DrivePort {
  DrivePort(
    fetch_start_page_token: fn() -> Result(String, String),
    /// Real root id + full files.list snapshot.
    fetch_mirror_snapshot: fn() ->
      Result(#(String, List(RemoteSighting)), String),
    fetch_all_changes: fn(String) -> Result(#(List(Change), String), String),
  )
}

pub type PollerConfig {
  PollerConfig(
    drive: DrivePort,
    state_owner: Subject(state_owner.Command),
    deliver: Subject(reconciler.Command),
    poll_interval_ms: Int,
    pick_retry_delay_ms: fn(Int) -> Int,
  )
}

type State {
  State(
    config: PollerConfig,
    self: Subject(Command),
    failed_attempts: Int,
    seeded: Bool,
  )
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
    seeded: False,
  ))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Poll -> {
      let outcome = case state.seeded {
        False -> seed_mirror(state.config)
        True -> advance_changes(state.config)
      }
      case outcome {
        Ok(Nil) -> {
          process.send_after(state.self, state.config.poll_interval_ms, Poll)
          actor.continue(
            State(..state, failed_attempts: 0, seeded: True),
          )
        }
        Error(_reason) -> {
          let delay = state.config.pick_retry_delay_ms(state.failed_attempts)
          process.send_after(state.self, delay, Poll)
          actor.continue(
            State(..state, failed_attempts: state.failed_attempts + 1),
          )
        }
      }
    }
  }
}

fn seed_mirror(config: PollerConfig) -> Result(Nil, String) {
  // Token first: changes that happen during the listing get replayed later.
  use Nil <- result.try(ensure_page_token(config))
  use #(root_id, files) <- result.try(config.drive.fetch_mirror_snapshot())
  process.send(config.deliver, reconciler.SeedMirror(root_id, files))
  Ok(Nil)
}

fn ensure_page_token(config: PollerConfig) -> Result(Nil, String) {
  case process.call(config.state_owner, 5000, state_owner.GetPageToken) {
    Some(_token) -> Ok(Nil)
    None -> {
      use token <- result.try(config.drive.fetch_start_page_token())
      process.send(config.state_owner, state_owner.SetPageToken(token))
      Ok(Nil)
    }
  }
}

fn advance_changes(config: PollerConfig) -> Result(Nil, String) {
  let assert Some(page_token) =
    process.call(config.state_owner, 5000, state_owner.GetPageToken)
  use #(changes, fresh_token) <- result.try(config.drive.fetch_all_changes(page_token))
  case changes {
    [] -> Nil
    changes ->
      process.send(
        config.deliver,
        reconciler.ApplyRemoteChanges(translate_changes(changes)),
      )
  }
  process.send(config.state_owner, state_owner.SetPageToken(fresh_token))
  Ok(Nil)
}

/// Map the Drive wire format onto the application's intake contract.
pub fn translate_changes(changes: List(Change)) -> List(RemoteObservation) {
  list.map(changes, fn(change) {
    case change {
      changes.Changed(file) -> reconciler.ObservedFile(translate_file(file))
      changes.Removed(file_id) -> reconciler.ObservedRemoval(file_id)
    }
  })
}

pub fn translate_file(file: ChangedFile) -> RemoteSighting {
  reconciler.RemoteSighting(
    file_id: file.file_id,
    name: file.name,
    mime_type: file.mime_type,
    parent_id: file.parent_id,
    modified_time: file.modified_time,
    size: file.size,
    md5: file.md5,
    trashed: file.trashed,
  )
}
