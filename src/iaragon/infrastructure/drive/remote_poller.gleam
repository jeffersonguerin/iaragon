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
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import iaragon/application/reconciler.{
  type RemoteObservation, type RemoteSighting,
}
import iaragon/application/state_owner
import iaragon/infrastructure/drive/changes.{type Change, type ChangedFile}

pub type Command {
  Poll
  /// The reconciler lost its in-memory model (it was restarted): seed again
  /// on the next cycle, which starts immediately.
  Reseed
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
    /// The one outstanding scheduled Poll. Cancelled and re-armed on every
    /// handled Poll so an out-of-band Poll (first kick, reseed) can never
    /// leave two polling chains running.
    scheduled_poll: option.Option(process.Timer),
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
  actor.new_with_initialiser(1000, fn(subject) {
    // Self-kick so polling (re)starts on every boot AND every supervisor
    // restart — nothing external re-sends Poll after a crash, so without
    // this a single transient poller crash would stop remote→local sync
    // until the whole daemon restarts.
    process.send(subject, Poll)
    actor.initialised(State(
      config: config,
      self: process.named_subject(name),
      failed_attempts: 0,
      seeded: False,
      scheduled_poll: None,
    ))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  case command {
    Reseed -> {
      process.send(state.self, Poll)
      actor.continue(State(..state, seeded: False))
    }
    Poll -> {
      // Only one scheduled Poll may be outstanding: an out-of-band Poll
      // (reseed, first kick) supersedes the pending one instead of forking
      // a second polling chain.
      case state.scheduled_poll {
        Some(timer) -> {
          let _ = process.cancel_timer(timer)
          Nil
        }
        None -> Nil
      }
      let outcome = case state.seeded {
        False -> seed_mirror(state.config)
        True -> advance_changes(state.config)
      }
      case outcome {
        Ok(Nil) -> {
          let timer =
            process.send_after(state.self, state.config.poll_interval_ms, Poll)
          actor.continue(
            State(
              ..state,
              failed_attempts: 0,
              seeded: True,
              scheduled_poll: Some(timer),
            ),
          )
        }
        Error(_reason) -> {
          let delay = state.config.pick_retry_delay_ms(state.failed_attempts)
          let timer = process.send_after(state.self, delay, Poll)
          actor.continue(
            State(
              ..state,
              failed_attempts: state.failed_attempts + 1,
              scheduled_poll: Some(timer),
            ),
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
  deliver(config, reconciler.SeedMirror(root_id, files))
}

/// Send to the reconciler, tolerating the brief startup/restart window where
/// its named subject is not yet registered: the reconciler starts AFTER the
/// poller in the tree, so a self-kicked seed can race ahead of it. A raw send
/// to an unregistered name raises and crashes the poller; instead report a
/// transient error so the Poll retry re-attempts once the reconciler is up.
/// Nothing is acknowledged (the seeded flag, the page token) until delivery
/// succeeds, so the seed/changes are never lost.
fn deliver(
  config: PollerConfig,
  message: reconciler.Command,
) -> Result(Nil, String) {
  case process.subject_owner(config.deliver) {
    Ok(_registered) -> {
      process.send(config.deliver, message)
      Ok(Nil)
    }
    Error(Nil) -> Error("reconciler not registered yet")
  }
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
  use #(changes, fresh_token) <- result.try(config.drive.fetch_all_changes(
    page_token,
  ))
  // Deliver BEFORE advancing the token: if the reconciler is momentarily
  // unregistered, report a transient error so the token is not advanced and
  // these changes are re-fetched (and re-delivered) on the retry.
  use Nil <- result.try(case changes {
    [] -> Ok(Nil)
    changes ->
      deliver(config, reconciler.ApplyRemoteChanges(translate_changes(changes)))
  })
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
    shortcut_target_id: file.shortcut_target_id,
    trashed: file.trashed,
  )
}
