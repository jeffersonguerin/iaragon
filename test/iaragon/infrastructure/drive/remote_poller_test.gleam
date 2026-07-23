import gleam/erlang/process.{type Subject}
import gleam/option.{Some}
import iaragon/application/reconciler
import iaragon/application/state_owner
import iaragon/infrastructure/drive/changes.{Removed}
import iaragon/infrastructure/drive/remote_poller.{DrivePort, PollerConfig}
import support/fakes

// The poller's first successful cycle always seeds the mirror (root id +
// full listing) — the in-memory remote model does not survive restarts.
// After that: fetch → deliver observations → advance token, retrying with
// backoff on refusals and re-polling on an interval.

fn a_sighting(file_id: String) -> reconciler.RemoteSighting {
  reconciler.RemoteSighting(
    file_id: file_id,
    name: "a.txt",
    mime_type: "text/plain",
    parent_id: Some("root-1"),
    modified_time: "2026-07-01T10:00:00Z",
    size: Some(42),
    md5: Some("aaa"),
    trashed: False,
    shortcut_target_id: option.None,
  )
}

fn a_port() -> remote_poller.DrivePort {
  DrivePort(
    fetch_start_page_token: fn() { Ok("tok-0") },
    fetch_mirror_snapshot: fn() { Ok(#("root-1", [a_sighting("id-1")])) },
    fetch_all_changes: fn(_page_token) { panic as "not expected in this test" },
  )
}

fn start_state_owner() -> Subject(state_owner.Command) {
  fakes.start_ephemeral_state_owner()
}

fn start_poller(
  owner: Subject(state_owner.Command),
  deliver: Subject(reconciler.Command),
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

pub fn the_poller_seeds_on_its_own_without_an_external_kick_test() {
  // The poller self-kicks on init: nothing external needs to send Poll, so
  // a supervisor restart resumes polling on its own (the crash that would
  // otherwise stop remote→local sync forever).
  let owner = start_state_owner()
  let deliver = process.new_subject()
  let _poller = start_poller(owner, deliver, a_port(), idle_interval)

  assert process.receive(deliver, 1000)
    == Ok(reconciler.SeedMirror("root-1", [a_sighting("id-1")]))
  assert wait_for_page_token(owner, Some("tok-0"))
}

pub fn a_restart_with_a_persisted_token_still_seeds_first_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      ..a_port(),
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: fn(_page_token) { Ok(#([Removed("id-9")], "tok-2")) },
    )
  let poller = start_poller(owner, deliver, port, idle_interval)

  let assert Ok(reconciler.SeedMirror("root-1", _)) =
    process.receive(deliver, 1000)

  // The next cycle flows changes as observations.
  process.send(poller, remote_poller.Poll)
  assert process.receive(deliver, 1000)
    == Ok(reconciler.ApplyRemoteChanges([reconciler.ObservedRemoval("id-9")]))
  assert wait_for_page_token(owner, Some("tok-2"))
}

pub fn changed_files_are_translated_into_observations_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let changed =
    changes.ChangedFile(
      file_id: "id-1",
      name: "a.txt",
      mime_type: "text/plain",
      parent_id: Some("root-1"),
      modified_time: "2026-07-01T10:00:00Z",
      size: Some(42),
      md5: Some("aaa"),
      trashed: False,
      shortcut_target_id: option.None,
    )
  let port =
    DrivePort(
      ..a_port(),
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: fn(_page_token) {
        Ok(#([changes.Changed(changed), Removed("id-2")], "tok-2"))
      },
    )
  let poller = start_poller(owner, deliver, port, idle_interval)

  let assert Ok(reconciler.SeedMirror(_, _)) = process.receive(deliver, 1000)

  process.send(poller, remote_poller.Poll)
  assert process.receive(deliver, 1000)
    == Ok(
      reconciler.ApplyRemoteChanges([
        reconciler.ObservedFile(a_sighting("id-1")),
        reconciler.ObservedRemoval("id-2"),
      ]),
    )
}

pub fn an_empty_change_list_advances_without_delivering_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      ..a_port(),
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: fn(_page_token) { Ok(#([], "tok-2")) },
    )
  let poller = start_poller(owner, deliver, port, idle_interval)

  let assert Ok(reconciler.SeedMirror(_, _)) = process.receive(deliver, 1000)

  process.send(poller, remote_poller.Poll)
  assert wait_for_page_token(owner, Some("tok-2"))
  assert process.receive(deliver, 100) == Error(Nil)
}

pub fn a_failed_seed_is_retried_until_it_succeeds_test() {
  let owner = start_state_owner()
  let deliver = process.new_subject()
  let outcomes =
    fakes.script_outcomes([
      Error("429 slow down"),
      Ok(#("root-1", [a_sighting("id-1")])),
    ])
  let port = DrivePort(..a_port(), fetch_mirror_snapshot: fn() { outcomes() })
  let _poller = start_poller(owner, deliver, port, idle_interval)

  // Auto-kick seeds; the first attempt fails and the retry succeeds.
  let assert Ok(reconciler.SeedMirror("root-1", _)) =
    process.receive(deliver, 2000)
}

pub fn a_reseed_request_makes_the_next_cycle_seed_again_test() {
  let owner = start_state_owner()
  let deliver = process.new_subject()
  let poller = start_poller(owner, deliver, a_port(), idle_interval)
  let assert Ok(reconciler.SeedMirror(_, _)) = process.receive(deliver, 1000)

  // The reconciler lost its model (restart) and asks for a fresh seed.
  process.send(poller, remote_poller.Reseed)

  let assert Ok(reconciler.SeedMirror("root-1", _)) =
    process.receive(deliver, 2000)
  Nil
}

pub fn polling_repeats_on_the_configured_interval_test() {
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("tok-1"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      ..a_port(),
      fetch_start_page_token: fn() { panic as "token already known" },
      fetch_all_changes: fn(_page_token) { Ok(#([Removed("id-1")], "tok-2")) },
    )
  let _poller = start_poller(owner, deliver, port, 25)

  // Seed on the first cycle, then interval-driven change deliveries.
  let assert Ok(reconciler.SeedMirror(_, _)) = process.receive(deliver, 1000)
  let assert Ok(reconciler.ApplyRemoteChanges(_)) =
    process.receive(deliver, 1000)
  let assert Ok(reconciler.ApplyRemoteChanges(_)) =
    process.receive(deliver, 1000)
}

pub fn a_stale_page_token_reseeds_instead_of_looping_test() {
  // A persisted token that Drive rejects (too old / invalid) must not be
  // retried forever: the poller fetches a fresh startPageToken, persists it,
  // and re-seeds with a full snapshot (an unknown number of changes may have
  // been missed while the token was stale).
  let owner = start_state_owner()
  process.send(owner, state_owner.SetPageToken("stale-tok"))
  let deliver = process.new_subject()
  let port =
    DrivePort(
      ..a_port(),
      fetch_start_page_token: fn() { Ok("fresh-tok") },
      fetch_all_changes: fn(_page_token) { Error(remote_poller.StalePageToken) },
    )
  let poller = start_poller(owner, deliver, port, idle_interval)

  // First cycle seeds against the (still-present) stale token.
  let assert Ok(reconciler.SeedMirror("root-1", _)) =
    process.receive(deliver, 1000)

  // Next cycle advances, the token is rejected, and the poller re-seeds.
  process.send(poller, remote_poller.Poll)
  let assert Ok(reconciler.SeedMirror("root-1", _)) =
    process.receive(deliver, 2000)
  assert wait_for_page_token(owner, Some("fresh-tok"))
}

pub fn an_unregistered_reconciler_does_not_crash_the_poller_test() {
  let owner = start_state_owner()
  // The reconciler starts AFTER the poller in the supervision tree, so at
  // boot the poller may self-kick and seed before the reconciler's named
  // subject is registered. Delivering to an unregistered name must not crash
  // the poller (a raw send would raise) — it must retry until the reconciler
  // is up, never losing the seed.
  let deliver = process.named_subject(process.new_name(prefix: "absent_recon"))
  let calls = process.new_subject()
  let port =
    DrivePort(..a_port(), fetch_mirror_snapshot: fn() {
      process.send(calls, Nil)
      Ok(#("root-1", [a_sighting("id-1")]))
    })
  let poller = start_poller(owner, deliver, port, idle_interval)

  // Two snapshot fetches prove the poller retried rather than crashing on the
  // first unregistered delivery.
  let assert Ok(Nil) = process.receive(calls, 1000)
  let assert Ok(Nil) = process.receive(calls, 1000)
  // And the poller process is still alive.
  assert process.subject_owner(poller) != Error(Nil)
}

fn wait_for_page_token(
  owner: Subject(state_owner.Command),
  expected: option.Option(String),
) -> Bool {
  fakes.retry_until(40, fn() {
    process.call(owner, 500, state_owner.GetPageToken) == expected
  })
}
