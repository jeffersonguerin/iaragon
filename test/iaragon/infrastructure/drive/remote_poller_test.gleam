import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import iaragon/application/state_owner
import iaragon/infrastructure/drive/changes.{Removed}
import iaragon/infrastructure/drive/remote_poller.{DrivePort, PollerConfig}

// The poller drives the Changes API: bootstrap the start page token on the
// first run, then fetch → deliver → advance token, retrying with backoff on
// refusals and re-polling on an interval. The Drive port is faked with a
// scripted sequence of responses.

type FetchOutcome =
  Result(#(List(changes.Change), String), String)

type ScriptCommand {
  PopNext(reply: Subject(FetchOutcome))
}

/// A stateful fake: each fetch_all_changes call consumes the next scripted
/// response (the last one repeats forever).
fn script_fetches(outcomes: List(FetchOutcome)) -> fn(String) -> FetchOutcome {
  let assert Ok(started) =
    actor.new(outcomes)
    |> actor.on_message(fn(remaining, command: ScriptCommand) {
      let assert [current, ..rest] = remaining
      process.send(command.reply, current)
      case rest {
        [] -> actor.continue([current])
        rest -> actor.continue(rest)
      }
    })
    |> actor.start
  fn(_page_token) { process.call(started.data, 1000, PopNext) }
}

fn an_ephemeral_store() -> state_owner.StateStore {
  state_owner.StateStore(
    load_all_known: fn() { Ok([]) },
    load_page_token: fn() { Ok(None) },
    put_known: fn(_) { Ok(Nil) },
    forget_known: fn(_) { Ok(Nil) },
    save_page_token: fn(_) { Ok(Nil) },
  )
}

fn start_state_owner() -> Subject(state_owner.Command) {
  let name = process.new_name(prefix: "poller_test_state_owner")
  let assert Ok(_) = state_owner.start(name, an_ephemeral_store())
  process.named_subject(name)
}

fn start_poller(
  owner: Subject(state_owner.Command),
  deliver: Subject(List(changes.Change)),
  port: remote_poller.DrivePort,
  poll_interval_ms: Int,
) -> Subject(remote_poller.Command) {
  let name = process.new_name(prefix: "poller_test")
  let assert Ok(_) =
    remote_poller.start(
      name,
      PollerConfig(
        drive: port,
        state_owner: owner,
        deliver: deliver,
        poll_interval_ms: poll_interval_ms,
        pick_retry_delay_ms: fn(_attempt) { 25 },
      ),
    )
  process.named_subject(name)
}

const idle_interval = 60_000

pub fn the_first_poll_bootstraps_the_start_page_token_test() {
  let owner = start_state_owner()
  let deliver = process.new_subject()
  let port =
    DrivePort(fetch_start_page_token: fn() { Ok("tok-0") }, fetch_all_changes: fn(_) {
      panic as "no changes fetch expected before a token exists"
    })
  let poller = start_poller(owner, deliver, port, idle_interval)

  process.send(poller, remote_poller.Poll)

  assert wait_for_page_token(owner, Some("tok-0"))
  // Nothing is delivered on bootstrap.
  assert process.receive(deliver, 100) == Error(Nil)
}

pub fn polling_delivers_changes_and_advances_the_token_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: script_fetches([Ok(#([Removed("id-1")], "tok-2"))]),
    )
  let poller = start_poller(owner, deliver, port, idle_interval)

  process.send(poller, remote_poller.Poll)

  assert process.receive(deliver, 1000) == Ok([Removed("id-1")])
  assert wait_for_page_token(owner, Some("tok-2"))
}

pub fn an_empty_change_list_still_advances_but_delivers_nothing_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: script_fetches([Ok(#([], "tok-2"))]),
    )
  let poller = start_poller(owner, deliver, port, idle_interval)

  process.send(poller, remote_poller.Poll)

  assert wait_for_page_token(owner, Some("tok-2"))
  assert process.receive(deliver, 100) == Error(Nil)
}

pub fn a_failed_poll_retries_until_it_succeeds_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: script_fetches([
        Error("429 slow down"),
        Error("429 still busy"),
        Ok(#([Removed("id-9")], "tok-2")),
      ]),
    )
  let poller = start_poller(owner, deliver, port, idle_interval)

  process.send(poller, remote_poller.Poll)

  // Two scripted refusals × 25 ms retry delay, then success.
  assert process.receive(deliver, 2000) == Ok([Removed("id-9")])
  assert wait_for_page_token(owner, Some("tok-2"))
}

pub fn polling_repeats_on_the_configured_interval_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: script_fetches([
        Ok(#([Removed("id-1")], "tok-2")),
        Ok(#([Removed("id-2")], "tok-3")),
      ]),
    )
  let poller = start_poller(owner, deliver, port, 25)

  process.send(poller, remote_poller.Poll)

  assert process.receive(deliver, 1000) == Ok([Removed("id-1")])
  assert process.receive(deliver, 1000) == Ok([Removed("id-2")])
}

/// GetPageToken goes through the same mailbox as the poller's own sends, so
/// a couple of retries absorb scheduling races without a fixed sleep.
fn wait_for_page_token(
  owner: Subject(state_owner.Command),
  expected: option.Option(String),
) -> Bool {
  retry_until(40, fn() {
    process.call(owner, 500, state_owner.GetPageToken) == expected
  })
}

fn retry_until(attempts: Int, check: fn() -> Bool) -> Bool {
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
