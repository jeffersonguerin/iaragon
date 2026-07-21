import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/string
import iaragon/application/state_owner
import iaragon/domain/entry.{
  Blob, Folder, GoogleNative, LinkFile, RemoteFile, Shortcut,
}
import iaragon/infrastructure/drive/transfer_pool.{TransferConfig}
import simplifile
import support/fakes

// The pool executes the reconciler's download-only decisions against the
// real filesystem (scratch dirs) with the network injected. Every success
// must be recorded in the state owner — that record IS the sync.

const scratch_dir = "build/test-scratch/transfer_pool"

fn a_remote(file_id: String, path: String) -> entry.RemoteFile {
  RemoteFile(
    file_id: file_id,
    name: path,
    path: path,
    mime_type: "text/plain",
    parent_id: Some("p-1"),
    modified_time: "2026-07-01T10:00:00Z",
    size: Some(11),
    md5: Some("aaa"),
    trashed: False,
    kind: Blob,
  )
}

fn start_pool(
  case_name: String,
  owner: Subject(state_owner.Command),
  fetch: fn(String, String) -> Result(Nil, String),
) -> #(Subject(transfer_pool.Command), String) {
  let root = scratch_dir <> "/" <> case_name
  let name = process.new_name(prefix: "transfer_pool_test")
  let assert Ok(_) =
    transfer_pool.start(
      name,
      TransferConfig(
        root_dir: root,
        fetch_to_disk: fetch,
        state_owner: owner,
        native_policy: LinkFile,
        pick_retry_delay_ms: fn(_attempt) { 25 },
      ),
    )
  #(process.named_subject(name), root)
}

fn a_working_fetch() -> fn(String, String) -> Result(Nil, String) {
  fn(_file_id, destination) {
    let assert Ok(Nil) =
      simplifile.write(to: destination, contents: "hello bytes")
    Ok(Nil)
  }
}

fn known_of(
  owner: Subject(state_owner.Command),
  file_id: String,
) -> option.Option(entry.KnownFile) {
  process.call(owner, 500, state_owner.GetKnown(file_id, _))
}

pub fn a_downloaded_blob_is_recorded_as_known_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let #(pool, root) = start_pool("blob", owner, a_working_fetch())

  process.send(
    pool,
    transfer_pool.EnqueueDownload(a_remote("id-1", "docs/report.txt")),
  )

  assert fakes.retry_until(40, fn() { known_of(owner, "id-1") != None })
  assert simplifile.read(root <> "/docs/report.txt") == Ok("hello bytes")
  let assert Some(known) = known_of(owner, "id-1")
  assert known.path == "docs/report.txt"
  assert known.md5 == Some("aaa")
  assert known.size == 11
  assert known.local_mtime_seconds > 0
  assert known.kind == Blob
}

pub fn a_folder_is_created_and_recorded_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let #(pool, root) = start_pool("folder", owner, a_working_fetch())
  let folder =
    RemoteFile(..a_remote("id-f", "docs"), size: None, md5: None, kind: Folder)

  process.send(pool, transfer_pool.EnqueueDownload(folder))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-f") != None })
  assert simplifile.is_directory(root <> "/docs") == Ok(True)
  let assert Some(known) = known_of(owner, "id-f")
  assert known.kind == Folder
}

pub fn a_native_doc_becomes_a_link_file_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let #(pool, root) = start_pool("native", owner, a_working_fetch())
  let native =
    RemoteFile(
      ..a_remote("id-doc", "notes.desktop"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
      kind: GoogleNative,
    )

  process.send(pool, transfer_pool.EnqueueDownload(native))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-doc") != None })
  let assert Ok(contents) = simplifile.read(root <> "/notes.desktop")
  assert string.contains(contents, "https://drive.google.com/open?id=id-doc")
  assert string.contains(contents, "[Desktop Entry]")
  let assert Some(known) = known_of(owner, "id-doc")
  assert known.kind == GoogleNative
}

pub fn a_shortcut_links_to_its_target_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let #(pool, root) = start_pool("shortcut", owner, a_working_fetch())
  let shortcut =
    RemoteFile(
      ..a_remote("id-s", "link.desktop"),
      size: None,
      md5: None,
      kind: Shortcut("id-target"),
    )

  process.send(pool, transfer_pool.EnqueueDownload(shortcut))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-s") != None })
  let assert Ok(contents) = simplifile.read(root <> "/link.desktop")
  assert string.contains(contents, "https://drive.google.com/open?id=id-target")
}

pub fn deleting_locally_removes_the_file_and_forgets_it_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let #(pool, root) = start_pool("delete", owner, a_working_fetch())
  let remote = a_remote("id-1", "old.txt")
  process.send(pool, transfer_pool.EnqueueDownload(remote))
  assert fakes.retry_until(40, fn() { known_of(owner, "id-1") != None })

  process.send(pool, transfer_pool.EnqueueDeleteLocal("id-1", "old.txt"))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-1") == None })
  assert simplifile.is_file(root <> "/old.txt") == Ok(False)
}

pub fn failed_downloads_are_retried_until_success_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let outcomes = fakes.script_outcomes([Error("boom"), Error("boom"), Ok(Nil)])
  let fetch = fn(_file_id, destination) {
    case outcomes() {
      Ok(Nil) -> {
        let assert Ok(Nil) = simplifile.write(to: destination, contents: "ok!")
        Ok(Nil)
      }
      Error(reason) -> Error(reason)
    }
  }
  let #(pool, root) = start_pool("retry", owner, fetch)

  process.send(
    pool,
    transfer_pool.EnqueueDownload(a_remote("id-1", "flaky.txt")),
  )

  assert fakes.retry_until(80, fn() { known_of(owner, "id-1") != None })
  assert simplifile.read(root <> "/flaky.txt") == Ok("ok!")
}

pub fn downloads_that_keep_failing_are_dropped_not_crashed_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let fetch = fn(_file_id, _destination) { Error("always down") }
  let #(pool, _root) = start_pool("give-up", owner, fetch)

  process.send(
    pool,
    transfer_pool.EnqueueDownload(a_remote("id-1", "never.txt")),
  )
  // Give the retries time to burn out, then prove the pool is still alive
  // and never recorded the failed download.
  process.sleep(300)
  assert known_of(owner, "id-1") == None

  // A folder needs no fetch: if it lands, the pool survived the give-up.
  let probe =
    RemoteFile(..a_remote("id-2", "alive"), size: None, md5: None, kind: Folder)
  process.send(pool, transfer_pool.EnqueueDownload(probe))
  assert fakes.retry_until(40, fn() { known_of(owner, "id-2") != None })
}
