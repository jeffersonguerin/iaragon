import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import iaragon/application/reconciler.{
  ObservedFile, ObservedRemoval, ReconcilerConfig, RemoteSighting,
}
import iaragon/application/state_owner
import iaragon/domain/entry.{Blob, GoogleNative, KnownFile, LinkFile, LocalFile}
import support/fakes

// The reconciler holds the remote model (seeded by the initial listing, kept
// fresh by change observations), resolves paths, runs the pure three-way
// reconciliation and dispatches download-only actions through injected
// functions. Upload-side decisions are ignored in this phase.

type Dispatch {
  DownloadDispatched(remote: entry.RemoteFile)
  DeleteLocalDispatched(file_id: String, path: String)
}

fn a_sighting(
  file_id: String,
  name: String,
  parent: String,
) -> reconciler.RemoteSighting {
  RemoteSighting(
    file_id: file_id,
    name: name,
    mime_type: "text/plain",
    parent_id: Some(parent),
    modified_time: "2026-07-01T10:00:00Z",
    size: Some(42),
    md5: Some("aaa"),
    trashed: False,
  )
}

fn a_folder_sighting(
  file_id: String,
  name: String,
  parent: String,
) -> reconciler.RemoteSighting {
  RemoteSighting(
    ..a_sighting(file_id, name, parent),
    mime_type: "application/vnd.google-apps.folder",
    size: None,
    md5: None,
  )
}

fn start_reconciler(
  owner: Subject(state_owner.Command),
  dispatches: Subject(Dispatch),
  locals: List(entry.LocalFile),
  hash_outcome: Result(String, String),
) -> Subject(reconciler.Command) {
  let name = process.new_name(prefix: "reconciler_test")
  let assert Ok(_) =
    reconciler.start(
      name,
      ReconcilerConfig(
        state_owner: owner,
        dispatch_download: fn(remote) {
          process.send(dispatches, DownloadDispatched(remote))
        },
        dispatch_delete_local: fn(file_id, path) {
          process.send(dispatches, DeleteLocalDispatched(file_id, path))
        },
        scan_local: fn() { Ok(locals) },
        hash_local_file: fn(_path) { hash_outcome },
        native_policy: LinkFile,
      ),
    )
  process.named_subject(name)
}

pub fn seeding_downloads_the_whole_remote_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("no hash needed"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [
      a_folder_sighting("id-docs", "docs", "root"),
      a_sighting("id-1", "report.txt", "id-docs"),
    ]),
  )

  let assert Ok(first) = process.receive(dispatches, 1000)
  let assert Ok(second) = process.receive(dispatches, 1000)
  let downloads =
    list.filter_map([first, second], fn(dispatch) {
      case dispatch {
        DownloadDispatched(remote) ->
          Ok(#(remote.file_id, remote.path, remote.kind))
        _ -> Error(Nil)
      }
    })
  assert list.contains(downloads, #("id-docs", "docs", entry.Folder))
  assert list.contains(downloads, #("id-1", "docs/report.txt", Blob))
}

pub fn files_already_synced_are_left_alone_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let known =
    KnownFile(
      file_id: "id-1",
      path: "report.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )
  process.send(owner, state_owner.PutKnown(known))
  let local =
    LocalFile(path: "report.txt", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )

  assert process.receive(dispatches, 300) == Error(Nil)
}

pub fn a_remote_removal_deletes_the_local_copy_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let known =
    KnownFile(
      file_id: "id-1",
      path: "report.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )
  process.send(owner, state_owner.PutKnown(known))
  let local =
    LocalFile(path: "report.txt", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))
  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )

  process.send(sut, reconciler.ApplyRemoteChanges([ObservedRemoval("id-1")]))

  assert process.receive(dispatches, 1000)
    == Ok(DeleteLocalDispatched("id-1", "report.txt"))
}

pub fn a_trashed_file_counts_as_removed_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let known =
    KnownFile(
      file_id: "id-1",
      path: "report.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )
  process.send(owner, state_owner.PutKnown(known))
  let local =
    LocalFile(path: "report.txt", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))
  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )

  let trashed =
    RemoteSighting(..a_sighting("id-1", "report.txt", "root"), trashed: True)
  process.send(sut, reconciler.ApplyRemoteChanges([ObservedFile(trashed)]))

  assert process.receive(dispatches, 1000)
    == Ok(DeleteLocalDispatched("id-1", "report.txt"))
}

pub fn identical_never_synced_twins_are_adopted_without_transfer_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local =
    LocalFile(path: "report.txt", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  // The on-demand hash proves the local twin matches the remote md5.
  let sut = start_reconciler(owner, dispatches, [local], Ok("aaa"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )

  assert process.receive(dispatches, 300) == Error(Nil)
}

pub fn native_docs_are_planned_as_link_files_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))
  let native =
    RemoteSighting(
      ..a_sighting("id-doc", "notes", "root"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
    )

  process.send(sut, reconciler.SeedMirror("root", [native]))

  let assert Ok(DownloadDispatched(remote)) = process.receive(dispatches, 1000)
  assert remote.path == "notes.desktop"
  assert remote.kind == GoogleNative
}

pub fn upload_side_decisions_are_ignored_in_download_only_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local_only =
    LocalFile(path: "mine.txt", size: 1, mtime_seconds: 1, md5: Some("zzz"))
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local_only], Error("unused"))

  process.send(sut, reconciler.SeedMirror("root", []))

  assert process.receive(dispatches, 300) == Error(Nil)
}

pub fn changes_arriving_before_the_seed_are_ignored_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))

  process.send(sut, reconciler.ApplyRemoteChanges([ObservedRemoval("id-1")]))

  assert process.receive(dispatches, 300) == Error(Nil)
}
