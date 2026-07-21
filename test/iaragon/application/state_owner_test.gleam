import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import iaragon/application/state_owner.{StateStore}
import iaragon/domain/entry.{Blob, KnownFile}

// The state owner works from an in-memory cache but writes every mutation
// through the injected StateStore port. The fake store records mutations in
// a subject so tests can assert the write-through.

pub type StoreCall {
  PutCalled(entry.KnownFile)
  ForgetCalled(String)
  SavePageTokenCalled(String)
}

fn a_recording_store(
  calls: Subject(StoreCall),
  preloaded: List(entry.KnownFile),
  page_token: option.Option(String),
) -> state_owner.StateStore {
  StateStore(
    load_all_known: fn() { Ok(preloaded) },
    load_page_token: fn() { Ok(page_token) },
    put_known: fn(file) {
      process.send(calls, PutCalled(file))
      Ok(Nil)
    },
    forget_known: fn(file_id) {
      process.send(calls, ForgetCalled(file_id))
      Ok(Nil)
    },
    save_page_token: fn(token) {
      process.send(calls, SavePageTokenCalled(token))
      Ok(Nil)
    },
  )
}

fn a_known(file_id: String) -> entry.KnownFile {
  KnownFile(
    file_id: file_id,
    path: "docs/report.txt",
    remote_modified_time: "2026-07-01T10:00:00Z",
    md5: Some("aaa"),
    size: 42,
    local_mtime_seconds: 1000,
    kind: Blob,
  )
}

fn start_owner(
  store: state_owner.StateStore,
) -> Subject(state_owner.Command) {
  let name = process.new_name(prefix: "state_owner_test")
  let assert Ok(_started) = state_owner.start(name, store)
  process.named_subject(name)
}

pub fn initial_state_is_loaded_from_the_store_test() {
  let calls = process.new_subject()
  let known = a_known("id-9")
  let owner = start_owner(a_recording_store(calls, [known], Some("tok-9")))

  assert process.call(owner, 500, state_owner.GetKnown("id-9", _))
    == Some(known)
  assert process.call(owner, 500, state_owner.GetPageToken) == Some("tok-9")
}

pub fn put_known_caches_and_writes_through_test() {
  let calls = process.new_subject()
  let owner = start_owner(a_recording_store(calls, [], None))
  let known = a_known("id-1")

  process.send(owner, state_owner.PutKnown(known))
  assert process.call(owner, 500, state_owner.GetKnown("id-1", _))
    == Some(known)
  assert process.receive(calls, 500) == Ok(PutCalled(known))
}

pub fn forget_known_evicts_and_writes_through_test() {
  let calls = process.new_subject()
  let known = a_known("id-1")
  let owner = start_owner(a_recording_store(calls, [known], None))

  process.send(owner, state_owner.ForgetKnown("id-1"))
  assert process.call(owner, 500, state_owner.GetKnown("id-1", _)) == None
  assert process.receive(calls, 500) == Ok(ForgetCalled("id-1"))
}

pub fn set_page_token_caches_and_writes_through_test() {
  let calls = process.new_subject()
  let owner = start_owner(a_recording_store(calls, [], None))

  process.send(owner, state_owner.SetPageToken("tok-1"))
  assert process.call(owner, 500, state_owner.GetPageToken) == Some("tok-1")
  assert process.receive(calls, 500) == Ok(SavePageTokenCalled("tok-1"))
}
