import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/string
import iaragon/application/reconciler.{UploadPlan}
import iaragon/application/state_owner
import iaragon/domain/entry.{
  Blob, Folder, GoogleNative, LinkFile, LocalFile, RemoteFile, Shortcut,
}
import iaragon/infrastructure/drive/changes
import iaragon/infrastructure/drive/transfer_pool.{TransferConfig}
import iaragon/infrastructure/drive/upload.{CreateFile, UpdateFile}
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

type UploadEvent {
  UploadCalled(target: upload.UploadTarget, source: String, size: Int)
  FolderCreated(name: String, parent_id: String)
  TrashCalled(file_id: String)
  UploadSettled(
    path: String,
    outcome: Result(reconciler.RemoteSighting, String),
  )
  TrashSettled(file_id: String, outcome: Result(Nil, String))
  FolderObserved(sighting: reconciler.RemoteSighting)
}

fn an_uploaded_file(file_id: String, name: String) -> changes.ChangedFile {
  changes.ChangedFile(
    file_id: file_id,
    name: name,
    mime_type: "text/plain",
    parent_id: Some("p-1"),
    modified_time: "2026-07-22T10:00:00Z",
    size: Some(3),
    md5: Some("m-up"),
    trashed: False,
    shortcut_target_id: None,
  )
}

fn a_pool_config(
  root: String,
  owner: Subject(state_owner.Command),
  fetch: fn(String, String) -> Result(Nil, String),
) -> transfer_pool.TransferConfig {
  TransferConfig(
    root_dir: root,
    fetch_to_disk: fetch,
    upload_to_drive: fn(_target, _source, _size) {
      panic as "no upload expected in this test"
    },
    create_remote_folder: fn(_name, _parent) {
      panic as "no folder creation expected in this test"
    },
    trash_remote: fn(_file_id) { panic as "no trash expected in this test" },
    rename_remote: fn(_file_id, _new_name, _add, _remove) {
      panic as "no remote rename expected in this test"
    },
    export_to_disk: fn(_file_id, _export_mime, _destination) {
      panic as "no export expected in this test"
    },
    signal_status: fn(_path, _status) { Nil },
    settle_upload: fn(_path, _outcome) { Nil },
    settle_trash: fn(_file_id, _outcome) { Nil },
    settle_conflict: fn(_path, _outcome) { Nil },
    settle_move: fn(_file_id, _outcome) { Nil },
    observe_folder: fn(_sighting) { Nil },
    state_owner: owner,
    native_policy: LinkFile,
    pick_retry_delay_ms: fn(_attempt) { 25 },
  )
}

fn start_pool_with(
  config: transfer_pool.TransferConfig,
) -> Subject(transfer_pool.Command) {
  let name = process.new_name(prefix: "transfer_pool_test")
  let assert Ok(_) = transfer_pool.start(name, config)
  process.named_subject(name)
}

fn start_pool(
  case_name: String,
  owner: Subject(state_owner.Command),
  fetch: fn(String, String) -> Result(Nil, String),
) -> #(Subject(transfer_pool.Command), String) {
  let root = scratch_dir <> "/" <> case_name
  #(start_pool_with(a_pool_config(root, owner, fetch)), root)
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

type ExportEvent {
  ExportCalled(file_id: String, export_mime: String)
}

pub fn a_native_doc_is_exported_under_the_office_policy_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/native-export"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      native_policy: entry.ExportOffice,
      export_to_disk: fn(file_id, export_mime, destination) {
        process.send(events, ExportCalled(file_id, export_mime))
        let assert Ok(Nil) =
          simplifile.write(to: destination, contents: "exported bytes")
        Ok(Nil)
      },
    )
  let pool = start_pool_with(config)
  // The reconciler already decided the export extension on the path.
  let native =
    RemoteFile(
      ..a_remote("id-doc", "notes.docx"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
      kind: GoogleNative,
    )

  process.send(pool, transfer_pool.EnqueueDownload(native))

  let assert Ok(ExportCalled("id-doc", export_mime)) =
    process.receive(events, 1000)
  assert export_mime
    == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  assert fakes.retry_until(40, fn() { known_of(owner, "id-doc") != None })
  assert simplifile.read(root <> "/notes.docx") == Ok("exported bytes")
  let assert Some(known) = known_of(owner, "id-doc")
  assert known.kind == GoogleNative
}

pub fn a_native_without_document_export_stays_a_link_under_export_policy_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/native-export-link"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      native_policy: entry.ExportOffice,
    )
  let pool = start_pool_with(config)
  let drawing =
    RemoteFile(
      ..a_remote("id-draw", "sketch.desktop"),
      mime_type: "application/vnd.google-apps.drawing",
      size: None,
      md5: None,
      kind: GoogleNative,
    )

  process.send(pool, transfer_pool.EnqueueDownload(drawing))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-draw") != None })
  let assert Ok(contents) = simplifile.read(root <> "/sketch.desktop")
  assert string.contains(contents, "https://drive.google.com/open?id=id-draw")
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

pub fn a_download_signals_syncing_then_synced_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let statuses = process.new_subject()
  let root = scratch_dir <> "/signal-download"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, a_working_fetch()),
      signal_status: fn(path, status) {
        process.send(statuses, #(path, status))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueDownload(a_remote("id-1", "docs/report.txt")),
  )

  assert process.receive(statuses, 1000)
    == Ok(#("docs/report.txt", entry.Syncing))
  assert process.receive(statuses, 1000)
    == Ok(#("docs/report.txt", entry.Synced))
}

pub fn an_upload_signals_syncing_then_synced_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let statuses = process.new_subject()
  let root = scratch_dir <> "/signal-upload"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/mine.txt", contents: "abc")
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      upload_to_drive: fn(_target, _source, _size) {
        Ok(an_uploaded_file("id-up", "mine.txt"))
      },
      settle_upload: fn(_path, _outcome) { Nil },
      signal_status: fn(path, status) {
        process.send(statuses, #(path, status))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueUpload(a_plan("mine.txt", "mine.txt")),
  )

  assert process.receive(statuses, 1000) == Ok(#("mine.txt", entry.Syncing))
  assert process.receive(statuses, 1000) == Ok(#("mine.txt", entry.Synced))
}

pub fn a_download_that_burns_its_retries_signals_failure_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let statuses = process.new_subject()
  let root = scratch_dir <> "/signal-failure"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("always down") }),
      signal_status: fn(path, status) {
        process.send(statuses, #(path, status))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueDownload(a_remote("id-1", "doomed.txt")),
  )

  // One Syncing per attempt; the give-up marks the failure visibly.
  assert process.receive(statuses, 1000) == Ok(#("doomed.txt", entry.Syncing))
  assert fakes.retry_until(80, fn() {
    case process.receive(statuses, 100) {
      Ok(#("doomed.txt", entry.SyncFailed)) -> True
      _ -> False
    }
  })
}

pub fn a_local_move_repaints_the_destination_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let statuses = process.new_subject()
  let root = scratch_dir <> "/signal-move"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/old.txt", contents: "bytes")
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      signal_status: fn(path, status) {
        process.send(statuses, #(path, status))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueMoveLocal(
      a_known_at("id-1", "renamed.txt"),
      from: "old.txt",
    ),
  )

  // A plain rename drops gvfs metadata, so the destination is repainted.
  assert process.receive(statuses, 1000) == Ok(#("renamed.txt", entry.Synced))
}

pub fn deleting_an_empty_directory_removes_and_forgets_it_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/delete-empty-dir"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/old-dir")
  let pool =
    start_pool_with(
      a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
    )
  process.send(
    owner,
    state_owner.PutKnown(
      entry.KnownFile(..a_known_at("id-f", "old-dir"), md5: None, kind: Folder),
    ),
  )

  process.send(pool, transfer_pool.EnqueueDeleteLocal("id-f", "old-dir"))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-f") == None })
  assert simplifile.is_directory(root <> "/old-dir") == Ok(False)
}

pub fn a_directory_with_content_is_left_alone_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/delete-full-dir"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/old-dir")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/old-dir/keep.txt", contents: "precious")
  let pool =
    start_pool_with(
      a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
    )
  process.send(
    owner,
    state_owner.PutKnown(
      entry.KnownFile(..a_known_at("id-f", "old-dir"), md5: None, kind: Folder),
    ),
  )

  process.send(pool, transfer_pool.EnqueueDeleteLocal("id-f", "old-dir"))

  // Deleting a directory that still has content would be data loss: the
  // pool must leave both the bytes and the bookkeeping untouched, so the
  // next round re-decides once the children are gone.
  process.sleep(150)
  assert simplifile.read(root <> "/old-dir/keep.txt") == Ok("precious")
  assert known_of(owner, "id-f") != None
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

// --- Uploads ------------------------------------------------------------------

fn a_plan(path: String, name: String) -> reconciler.UploadPlan {
  UploadPlan(
    local: LocalFile(path: path, size: 3, mtime_seconds: 1000, md5: None),
    name: name,
    existing_file_id: None,
    anchor_parent_id: "root-1",
    missing_folders: [],
  )
}

pub fn uploading_a_new_file_creates_records_and_settles_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/upload-new"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/mine.txt", contents: "abc")
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      upload_to_drive: fn(target, source, size) {
        process.send(events, UploadCalled(target, source, size))
        Ok(an_uploaded_file("id-up", "mine.txt"))
      },
      settle_upload: fn(path, outcome) {
        process.send(events, UploadSettled(path, outcome))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueUpload(a_plan("mine.txt", "mine.txt")),
  )

  let assert Ok(UploadCalled(target, source, 3)) = process.receive(events, 1000)
  assert target == CreateFile(name: "mine.txt", parent_id: "root-1")
  assert source == root <> "/mine.txt"
  let assert Ok(UploadSettled("mine.txt", Ok(sighting))) =
    process.receive(events, 1000)
  assert sighting.file_id == "id-up"
  assert fakes.retry_until(40, fn() { known_of(owner, "id-up") != None })
  let assert Some(known) = known_of(owner, "id-up")
  assert known.path == "mine.txt"
  assert known.md5 == Some("m-up")
}

pub fn uploading_a_modified_file_updates_in_place_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/upload-update"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/mine.txt", contents: "abc")
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      upload_to_drive: fn(target, _source, _size) {
        process.send(events, UploadCalled(target, "", 0))
        Ok(an_uploaded_file("id-9", "mine.txt"))
      },
      settle_upload: fn(_path, _outcome) { Nil },
    )
  let pool = start_pool_with(config)
  let plan =
    UploadPlan(..a_plan("mine.txt", "mine.txt"), existing_file_id: Some("id-9"))

  process.send(pool, transfer_pool.EnqueueUpload(plan))

  let assert Ok(UploadCalled(target, _, _)) = process.receive(events, 1000)
  assert target == UpdateFile(file_id: "id-9")
}

pub fn missing_folders_are_created_once_and_observed_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/upload-folders"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/docs")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/docs/a.txt", contents: "abc")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/docs/b.txt", contents: "abc")
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      create_remote_folder: fn(name, parent_id) {
        process.send(events, FolderCreated(name, parent_id))
        Ok(
          changes.ChangedFile(
            ..an_uploaded_file("id-docs", name),
            mime_type: "application/vnd.google-apps.folder",
            size: None,
            md5: None,
          ),
        )
      },
      observe_folder: fn(sighting) {
        process.send(events, FolderObserved(sighting))
      },
      upload_to_drive: fn(target, _source, _size) {
        process.send(events, UploadCalled(target, "", 0))
        Ok(an_uploaded_file("id-up", "a.txt"))
      },
      settle_upload: fn(_path, _outcome) { Nil },
    )
  let pool = start_pool_with(config)
  let first =
    UploadPlan(..a_plan("docs/a.txt", "a.txt"), missing_folders: ["docs"])
  let second =
    UploadPlan(..a_plan("docs/b.txt", "b.txt"), missing_folders: ["docs"])

  process.send(pool, transfer_pool.EnqueueUpload(first))
  process.send(pool, transfer_pool.EnqueueUpload(second))

  let assert Ok(FolderCreated("docs", "root-1")) = process.receive(events, 1000)
  let assert Ok(FolderObserved(folder)) = process.receive(events, 1000)
  assert folder.file_id == "id-docs"
  // First upload goes into the freshly created folder…
  let assert Ok(UploadCalled(CreateFile(_, "id-docs"), _, _)) =
    process.receive(events, 1000)
  // …and the second reuses the cache: no second FolderCreated event.
  let assert Ok(UploadCalled(CreateFile(_, "id-docs"), _, _)) =
    process.receive(events, 1000)
  assert process.receive(events, 200) == Error(Nil)
}

pub fn a_failed_upload_retries_then_settles_the_failure_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/upload-fail"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/mine.txt", contents: "abc")
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      upload_to_drive: fn(_target, _source, _size) { Error("always down") },
      settle_upload: fn(path, outcome) {
        process.send(events, UploadSettled(path, outcome))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueUpload(a_plan("mine.txt", "mine.txt")),
  )

  let assert Ok(UploadSettled("mine.txt", Error(_))) =
    process.receive(events, 2000)
  assert known_of(owner, "id-up") == None
}

// --- Local moves (remote renames) -----------------------------------------------

fn a_known_at(file_id: String, path: String) -> entry.KnownFile {
  entry.KnownFile(
    file_id: file_id,
    path: path,
    remote_modified_time: "2026-07-01T10:00:00Z",
    md5: Some("aaa"),
    size: 5,
    local_mtime_seconds: 1000,
    kind: Blob,
  )
}

pub fn a_move_relocates_the_file_and_updates_known_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/move"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/old.txt", contents: "bytes")
  let pool =
    start_pool_with(
      a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
    )

  process.send(
    pool,
    transfer_pool.EnqueueMoveLocal(
      a_known_at("id-1", "docs/renamed.txt"),
      from: "old.txt",
    ),
  )

  assert fakes.retry_until(40, fn() { known_of(owner, "id-1") != None })
  assert simplifile.read(root <> "/docs/renamed.txt") == Ok("bytes")
  assert simplifile.is_file(root <> "/old.txt") == Ok(False)
  let assert Some(known) = known_of(owner, "id-1")
  assert known.path == "docs/renamed.txt"
}

pub fn an_already_done_move_still_records_known_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/move-done"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  // The parent folder was renamed as a whole earlier: the file is already at
  // its destination and the source is gone.
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/renamed.txt", contents: "bytes")
  let pool =
    start_pool_with(
      a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
    )

  process.send(
    pool,
    transfer_pool.EnqueueMoveLocal(
      a_known_at("id-1", "renamed.txt"),
      from: "old.txt",
    ),
  )

  assert fakes.retry_until(40, fn() { known_of(owner, "id-1") != None })
  assert simplifile.read(root <> "/renamed.txt") == Ok("bytes")
}

pub fn a_folder_move_renames_the_directory_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/move-folder"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/old-dir")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/old-dir/child.txt", contents: "child")
  let pool =
    start_pool_with(
      a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
    )
  let folder =
    entry.KnownFile(..a_known_at("id-f", "new-dir"), md5: None, kind: Folder)

  process.send(pool, transfer_pool.EnqueueMoveLocal(folder, from: "old-dir"))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-f") != None })
  // A plain rename carries the children along in one go.
  assert simplifile.read(root <> "/new-dir/child.txt") == Ok("child")
  assert simplifile.is_directory(root <> "/old-dir") == Ok(False)
}

pub fn a_folder_move_into_an_occupied_destination_clears_the_empty_source_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/move-occupied"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  // The children were already carried one by one into a destination that
  // existed all along; only the empty source directory is left behind.
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/old-dir")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/new-dir")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/new-dir/child.txt", contents: "child")
  let pool =
    start_pool_with(
      a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
    )
  let folder =
    entry.KnownFile(..a_known_at("id-f", "new-dir"), md5: None, kind: Folder)

  process.send(pool, transfer_pool.EnqueueMoveLocal(folder, from: "old-dir"))

  assert fakes.retry_until(40, fn() { known_of(owner, "id-f") != None })
  assert simplifile.is_directory(root <> "/old-dir") == Ok(False)
  assert simplifile.read(root <> "/new-dir/child.txt") == Ok("child")
}

pub fn a_move_never_clears_a_source_that_still_has_content_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let root = scratch_dir <> "/move-occupied-full"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/old-dir")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/old-dir/keep.txt", contents: "precious")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/new-dir")
  let pool =
    start_pool_with(
      a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
    )
  let folder =
    entry.KnownFile(..a_known_at("id-f", "new-dir"), md5: None, kind: Folder)

  process.send(pool, transfer_pool.EnqueueMoveLocal(folder, from: "old-dir"))

  // Occupied destination AND a source with content: something is off — the
  // pool leaves the filesystem alone and lets the next round reconcile it.
  process.sleep(150)
  assert simplifile.read(root <> "/old-dir/keep.txt") == Ok("precious")
  assert known_of(owner, "id-f") == None
}

// --- Conflicted copies ----------------------------------------------------------

type ConflictEvent {
  ConflictSettled(path: String, outcome: Result(Nil, String))
}

const a_copy_path = "report (conflicted copy 2026-07-22).txt"

pub fn a_conflict_moves_local_aside_and_downloads_the_remote_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/conflict"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/report.txt", contents: "local edit")
  let fetch = fn(_file_id, destination) {
    let assert Ok(Nil) =
      simplifile.write(to: destination, contents: "remote content")
    Ok(Nil)
  }
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fetch),
      settle_conflict: fn(path, outcome) {
        process.send(events, ConflictSettled(path, outcome))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueConflictCopy(
      a_remote("id-1", "report.txt"),
      a_copy_path,
    ),
  )

  let assert Ok(ConflictSettled("report.txt", Ok(Nil))) =
    process.receive(events, 2000)
  assert simplifile.read(root <> "/" <> a_copy_path) == Ok("local edit")
  assert simplifile.read(root <> "/report.txt") == Ok("remote content")
  let assert Some(known) = known_of(owner, "id-1")
  assert known.path == "report.txt"
}

pub fn a_taken_copy_name_gets_a_numeric_variant_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/conflict-variant"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/report.txt", contents: "local edit")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/" <> a_copy_path, contents: "older conflict")
  let fetch = fn(_file_id, destination) {
    let assert Ok(Nil) = simplifile.write(to: destination, contents: "remote")
    Ok(Nil)
  }
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fetch),
      settle_conflict: fn(path, outcome) {
        process.send(events, ConflictSettled(path, outcome))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueConflictCopy(
      a_remote("id-1", "report.txt"),
      a_copy_path,
    ),
  )

  let assert Ok(ConflictSettled("report.txt", Ok(Nil))) =
    process.receive(events, 2000)
  // The earlier conflict file is untouched; the new copy takes a variant.
  assert simplifile.read(root <> "/" <> a_copy_path) == Ok("older conflict")
  assert simplifile.read(root <> "/report (conflicted copy 2026-07-22) (2).txt")
    == Ok("local edit")
}

pub fn a_failing_conflict_download_settles_the_failure_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/conflict-fail"
  // Wipe leftovers from earlier runs: these tests assert exact paths.
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/report.txt", contents: "local edit")
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("always down") }),
      settle_conflict: fn(path, outcome) {
        process.send(events, ConflictSettled(path, outcome))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueConflictCopy(
      a_remote("id-1", "report.txt"),
      a_copy_path,
    ),
  )

  let assert Ok(ConflictSettled("report.txt", Error(_))) =
    process.receive(events, 2000)
  Nil
}

// --- Remote moves (local renames) ------------------------------------------------

type MoveEvent {
  RenameCalled(
    file_id: String,
    new_name: String,
    add_parent_id: String,
    remove_parent_id: String,
  )
  MoveSettled(
    file_id: String,
    outcome: Result(reconciler.RemoteSighting, String),
  )
}

fn a_move_plan(to_path: String, name: String) -> reconciler.MoveRemotePlan {
  reconciler.MoveRemotePlan(
    file_id: "id-1",
    from_path: "old.txt",
    to_path: to_path,
    new_name: name,
    old_parent_id: "id-old-parent",
    anchor_parent_id: "root-1",
    missing_folders: [],
    local: LocalFile(path: to_path, size: 5, mtime_seconds: 1000, md5: None),
  )
}

pub fn a_remote_move_renames_without_any_transfer_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/remote-move"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      rename_remote: fn(file_id, new_name, add_parent_id, remove_parent_id) {
        process.send(
          events,
          RenameCalled(file_id, new_name, add_parent_id, remove_parent_id),
        )
        Ok(
          changes.ChangedFile(
            ..an_uploaded_file("id-1", new_name),
            parent_id: Some(add_parent_id),
          ),
        )
      },
      settle_move: fn(file_id, outcome) {
        process.send(events, MoveSettled(file_id, outcome))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueMoveRemote(a_move_plan("renamed.txt", "renamed.txt")),
  )

  let assert Ok(RenameCalled("id-1", "renamed.txt", "root-1", "id-old-parent")) =
    process.receive(events, 1000)
  let assert Ok(MoveSettled("id-1", Ok(sighting))) =
    process.receive(events, 1000)
  assert sighting.name == "renamed.txt"
  assert fakes.retry_until(40, fn() { known_of(owner, "id-1") != None })
  let assert Some(known) = known_of(owner, "id-1")
  assert known.path == "renamed.txt"
  assert known.size == 5
}

pub fn a_move_into_a_new_folder_creates_it_first_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/remote-move-folder"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      create_remote_folder: fn(name, parent_id) {
        process.send(events, RenameCalled("folder", name, parent_id, ""))
        Ok(
          changes.ChangedFile(
            ..an_uploaded_file("id-docs", name),
            mime_type: "application/vnd.google-apps.folder",
            size: None,
            md5: None,
          ),
        )
      },
      rename_remote: fn(file_id, new_name, add_parent_id, remove_parent_id) {
        process.send(
          events,
          RenameCalled(file_id, new_name, add_parent_id, remove_parent_id),
        )
        Ok(an_uploaded_file("id-1", new_name))
      },
      settle_move: fn(_file_id, _outcome) { Nil },
    )
  let pool = start_pool_with(config)
  let plan =
    reconciler.MoveRemotePlan(
      ..a_move_plan("docs/renamed.txt", "renamed.txt"),
      missing_folders: ["docs"],
    )

  process.send(pool, transfer_pool.EnqueueMoveRemote(plan))

  let assert Ok(RenameCalled("folder", "docs", "root-1", "")) =
    process.receive(events, 1000)
  let assert Ok(RenameCalled("id-1", "renamed.txt", "id-docs", "id-old-parent")) =
    process.receive(events, 1000)
  Nil
}

pub fn a_failing_remote_move_settles_the_failure_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/remote-move-fail"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      rename_remote: fn(_file_id, _new_name, _add, _remove) {
        Error("always down")
      },
      settle_move: fn(file_id, outcome) {
        process.send(events, MoveSettled(file_id, outcome))
      },
    )
  let pool = start_pool_with(config)

  process.send(
    pool,
    transfer_pool.EnqueueMoveRemote(a_move_plan("renamed.txt", "renamed.txt")),
  )

  let assert Ok(MoveSettled("id-1", Error(_))) = process.receive(events, 2000)
  assert known_of(owner, "id-1") == None
}

// --- Trash ----------------------------------------------------------------------

pub fn trashing_remotely_forgets_and_settles_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let events = process.new_subject()
  let root = scratch_dir <> "/trash"
  let config =
    transfer_pool.TransferConfig(
      ..a_pool_config(root, owner, fn(_id, _dest) { Error("unused") }),
      trash_remote: fn(file_id) {
        process.send(events, TrashCalled(file_id))
        Ok(Nil)
      },
      settle_trash: fn(file_id, outcome) {
        process.send(events, TrashSettled(file_id, outcome))
      },
    )
  let pool = start_pool_with(config)
  process.send(
    owner,
    state_owner.PutKnown(entry.KnownFile(
      file_id: "id-1",
      path: "gone.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 3,
      local_mtime_seconds: 1000,
      kind: Blob,
    )),
  )

  process.send(pool, transfer_pool.EnqueueTrashRemote("id-1"))

  let assert Ok(TrashCalled("id-1")) = process.receive(events, 1000)
  let assert Ok(TrashSettled("id-1", Ok(Nil))) = process.receive(events, 1000)
  assert fakes.retry_until(40, fn() { known_of(owner, "id-1") == None })
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
