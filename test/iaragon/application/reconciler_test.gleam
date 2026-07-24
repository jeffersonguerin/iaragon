import gleam/erlang/process.{type Subject}
import gleam/int
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
  UploadDispatched(plan: reconciler.UploadPlan)
  TrashDispatched(file_id: String)
  ConflictCopyDispatched(remote: entry.RemoteFile, copy_path: String)
  MoveLocalDispatched(updated: entry.KnownFile, from: String)
  MoveRemoteDispatched(plan: reconciler.MoveRemotePlan)
  SeedRequested
  LocalScanned
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
    shortcut_target_id: None,
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

const idle_round_interval = 600_000

fn start_reconciler_with_interval(
  owner: Subject(state_owner.Command),
  dispatches: Subject(Dispatch),
  locals: List(entry.LocalFile),
  hash_outcome: Result(String, String),
  round_interval_ms: Int,
  native_policy: entry.NativeDocPolicy,
  resolve_pool_pid: fn() -> Result(process.Pid, Nil),
) -> Subject(reconciler.Command) {
  let name = process.new_name(prefix: "reconciler_test")
  let assert Ok(_) =
    reconciler.start(
      name,
      ReconcilerConfig(
        state_owner: owner,
        resolve_pool_pid: resolve_pool_pid,
        dispatch_download: fn(remote, _expected) {
          process.send(dispatches, DownloadDispatched(remote))
        },
        dispatch_delete_local: fn(known: entry.KnownFile) {
          process.send(
            dispatches,
            DeleteLocalDispatched(known.file_id, known.path),
          )
        },
        dispatch_upload: fn(plan) {
          process.send(dispatches, UploadDispatched(plan))
        },
        dispatch_trash_remote: fn(file_id) {
          process.send(dispatches, TrashDispatched(file_id))
        },
        dispatch_conflict_copy: fn(remote, copy_path) {
          process.send(dispatches, ConflictCopyDispatched(remote, copy_path))
        },
        dispatch_move_local: fn(updated, from) {
          process.send(dispatches, MoveLocalDispatched(updated, from))
        },
        dispatch_move_remote: fn(plan) {
          process.send(dispatches, MoveRemoteDispatched(plan))
        },
        request_seed: fn() { process.send(dispatches, SeedRequested) },
        scan_local: fn() {
          process.send(dispatches, LocalScanned)
          Ok(locals)
        },
        hash_local_file: fn(_path) { hash_outcome },
        native_policy: native_policy,
        round_interval_ms: round_interval_ms,
        today: fn() { "2026-07-22" },
        report_trouble: fn(_line) { Nil },
        report_activity: fn(_line) { Nil },
        allow_mass_deletion: False,
      ),
    )
  process.named_subject(name)
}

fn start_reconciler(
  owner: Subject(state_owner.Command),
  dispatches: Subject(Dispatch),
  locals: List(entry.LocalFile),
  hash_outcome: Result(String, String),
) -> Subject(reconciler.Command) {
  start_reconciler_with_interval(
    owner,
    dispatches,
    locals,
    hash_outcome,
    idle_round_interval,
    LinkFile,
    fn() { Error(Nil) },
  )
}

/// An unlinked, name-registered stand-in for the transfer pool: killing it
/// fires the monitor the reconciler sets up, and its name auto-unregisters so
/// `subject_owner` reports it gone (exactly what the composition injects).
fn start_fake_pool() -> #(process.Pid, process.Name(Nil)) {
  let name = process.new_name(prefix: "fake_pool")
  let pid = process.spawn_unlinked(fn() { process.sleep_forever() })
  let assert Ok(Nil) = process.register(pid, name)
  #(pid, name)
}

fn receive_transfers(
  dispatches: Subject(Dispatch),
  count: Int,
) -> List(Dispatch) {
  case count {
    0 -> []
    _ ->
      case process.receive(dispatches, 1000) {
        // Scan notifications are bookkeeping, not transfers.
        Ok(LocalScanned) -> receive_transfers(dispatches, count)
        Ok(dispatch) -> [dispatch, ..receive_transfers(dispatches, count - 1)]
        Error(Nil) -> []
      }
  }
}

fn expect_no_transfers(dispatches: Subject(Dispatch)) -> Bool {
  case process.receive(dispatches, 300) {
    Ok(LocalScanned) -> expect_no_transfers(dispatches)
    Ok(_) -> False
    Error(Nil) -> True
  }
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

  let downloads =
    receive_transfers(dispatches, 2)
    |> list.filter_map(fn(dispatch) {
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

  assert expect_no_transfers(dispatches)
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

  assert receive_transfers(dispatches, 1)
    == [DeleteLocalDispatched("id-1", "report.txt")]
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

  assert receive_transfers(dispatches, 1)
    == [DeleteLocalDispatched("id-1", "report.txt")]
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

  assert expect_no_transfers(dispatches)
  // Adoption is bookkept: the twin link lands in the state owner, so later
  // rounds stop re-hashing the pair.
  let assert Some(known) =
    process.call(owner, 500, state_owner.GetKnown("id-1", _))
  assert known.path == "report.txt"
  assert known.md5 == Some("aaa")
  assert known.size == 42
  assert known.local_mtime_seconds == 1000
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

  let assert [DownloadDispatched(remote)] = receive_transfers(dispatches, 1)
  assert remote.path == "notes.desktop"
  assert remote.kind == GoogleNative
}

pub fn shortcuts_are_planned_as_links_to_their_target_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))
  let shortcut =
    RemoteSighting(
      ..a_sighting("id-s", "link to report", "root"),
      mime_type: "application/vnd.google-apps.shortcut",
      size: None,
      md5: None,
      shortcut_target_id: Some("id-target"),
    )

  process.send(sut, reconciler.SeedMirror("root", [shortcut]))

  let assert [DownloadDispatched(remote)] = receive_transfers(dispatches, 1)
  assert remote.path == "link to report.desktop"
  assert remote.kind == entry.Shortcut("id-target")
}

pub fn a_shortcut_without_its_target_stays_out_of_the_mirror_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))
  let shortcut =
    RemoteSighting(
      ..a_sighting("id-s", "broken link", "root"),
      mime_type: "application/vnd.google-apps.shortcut",
      size: None,
      md5: None,
    )

  process.send(sut, reconciler.SeedMirror("root", [shortcut]))

  assert expect_no_transfers(dispatches)
}

pub fn native_docs_are_planned_as_exports_under_the_office_policy_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut =
    start_reconciler_with_interval(
      owner,
      dispatches,
      [],
      Error("unused"),
      idle_round_interval,
      entry.ExportOffice,
      fn() { Error(Nil) },
    )
  let native =
    RemoteSighting(
      ..a_sighting("id-doc", "notes", "root"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
    )

  process.send(sut, reconciler.SeedMirror("root", [native]))

  let assert [DownloadDispatched(remote)] = receive_transfers(dispatches, 1)
  assert remote.path == "notes.docx"
  assert remote.kind == GoogleNative
}

pub fn a_policy_change_rematerializes_the_native_instead_of_moving_it_test() {
  let owner = fakes.start_ephemeral_state_owner()
  // Mirrored as a link back in the LinkFile era…
  process.send(
    owner,
    state_owner.PutKnown(
      KnownFile(
        ..a_synced_known("id-doc", "notes.desktop"),
        md5: None,
        kind: GoogleNative,
      ),
    ),
  )
  let stale_local =
    LocalFile(path: "notes.desktop", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  // …but the daemon now runs under the Office export policy.
  let sut =
    start_reconciler_with_interval(
      owner,
      dispatches,
      [stale_local],
      Error("unused"),
      idle_round_interval,
      entry.ExportOffice,
      fn() { Error(Nil) },
    )
  let native =
    RemoteSighting(
      ..a_sighting("id-doc", "notes", "root"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
    )

  process.send(sut, reconciler.SeedMirror("root", [native]))

  // Renaming notes.desktop to notes.docx would leave link bytes behind a
  // document extension: the stale file goes away and a real export lands.
  let assert [first, second] = receive_transfers(dispatches, 2)
  assert [first, second]
    |> list.contains(DeleteLocalDispatched("id-doc", "notes.desktop"))
  let assert Ok(DownloadDispatched(remote)) =
    [first, second]
    |> list.find(fn(dispatch) {
      case dispatch {
        DownloadDispatched(_) -> True
        _ -> False
      }
    })
  assert remote.path == "notes.docx"
}

pub fn a_pure_native_rename_still_moves_locally_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(
      KnownFile(
        ..a_synced_known("id-doc", "notes.desktop"),
        md5: None,
        kind: GoogleNative,
      ),
    ),
  )
  let local =
    LocalFile(path: "notes.desktop", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))
  // Same LinkFile policy, remote rename only: extension is unchanged.
  let native =
    RemoteSighting(
      ..a_sighting("id-doc", "plan", "root"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
    )

  process.send(sut, reconciler.SeedMirror("root", [native]))

  let assert [MoveLocalDispatched(updated, "notes.desktop")] =
    receive_transfers(dispatches, 1)
  assert updated.path == "plan.desktop"
}

pub fn a_local_trigger_while_unseeded_requests_a_reseed_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))

  // The actor was restarted and lost its model; a watcher ReconcileNow must
  // ask the poller to reseed, otherwise local edits are ignored until some
  // unrelated remote change happens to arrive.
  process.send(sut, reconciler.ReconcileNow)

  assert process.receive(dispatches, 1000) == Ok(SeedRequested)
}

pub fn changes_arriving_before_the_seed_request_a_reseed_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))

  // No model (e.g. this actor was just restarted by the supervisor): the
  // observations cannot be applied, so ask the poller for a fresh seed.
  process.send(sut, reconciler.ApplyRemoteChanges([ObservedRemoval("id-1")]))

  assert process.receive(dispatches, 1000) == Ok(SeedRequested)
  assert expect_no_transfers(dispatches)
}

pub fn a_remote_rename_dispatches_a_local_move_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(a_synced_known("id-1", "report.txt")),
  )
  let local =
    LocalFile(path: "report.txt", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "renamed.txt", "root")]),
  )

  let assert [MoveLocalDispatched(updated, "report.txt")] =
    receive_transfers(dispatches, 1)
  assert updated.file_id == "id-1"
  assert updated.path == "renamed.txt"
  // Everything but the path is carried over from the known snapshot.
  assert updated.md5 == Some("aaa")
  Nil
}

// --- Upload planning ----------------------------------------------------------

pub fn a_new_local_file_is_planned_for_upload_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local =
    LocalFile(
      path: "docs/mine.txt",
      size: 3,
      mtime_seconds: 1,
      md5: Some("zzz"),
    )
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_folder_sighting("id-docs", "docs", "root")]),
  )

  // The never-synced remote folder also gets materialised (bookkeeping);
  // the upload plan is what this test is about.
  let assert [plan] =
    receive_transfers(dispatches, 2)
    |> list.filter_map(fn(dispatch) {
      case dispatch {
        UploadDispatched(plan) -> Ok(plan)
        _ -> Error(Nil)
      }
    })
  assert plan.local == local
  assert plan.name == "mine.txt"
  assert plan.existing_file_id == None
  // "docs" already exists remotely: it anchors the upload, nothing to create.
  assert plan.anchor_parent_id == "id-docs"
  assert plan.missing_folders == []
}

pub fn a_file_in_a_brand_new_directory_lists_missing_folders_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local =
    LocalFile(
      path: "novo/sub/mine.txt",
      size: 3,
      mtime_seconds: 1,
      md5: Some("z"),
    )
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))

  process.send(sut, reconciler.SeedMirror("root", []))

  let assert [UploadDispatched(plan)] = receive_transfers(dispatches, 1)
  assert plan.anchor_parent_id == "root"
  assert plan.missing_folders == ["novo", "sub"]
}

pub fn a_modified_local_file_updates_in_place_test() {
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
  let edited =
    LocalFile(path: "report.txt", size: 43, mtime_seconds: 2000, md5: None)
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [edited], Error("unused"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )

  let assert [UploadDispatched(plan)] = receive_transfers(dispatches, 1)
  assert plan.existing_file_id == Some("id-1")
}

pub fn an_in_flight_upload_is_not_re_dispatched_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local =
    LocalFile(path: "mine.txt", size: 3, mtime_seconds: 1, md5: Some("zzz"))
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))
  process.send(sut, reconciler.SeedMirror("root", []))
  let assert [UploadDispatched(_)] = receive_transfers(dispatches, 1)

  process.send(sut, reconciler.ReconcileNow)

  assert expect_no_transfers(dispatches)
}

pub fn a_failed_upload_is_re_dispatched_after_settling_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local =
    LocalFile(path: "mine.txt", size: 3, mtime_seconds: 1, md5: Some("zzz"))
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))
  process.send(sut, reconciler.SeedMirror("root", []))
  let assert [UploadDispatched(_)] = receive_transfers(dispatches, 1)

  process.send(sut, reconciler.SettleUpload("mine.txt", Error("boom")))

  let assert [UploadDispatched(_)] = receive_transfers(dispatches, 1)
  Nil
}

pub fn a_settled_upload_stops_being_dispatched_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local =
    LocalFile(path: "mine.txt", size: 3, mtime_seconds: 1000, md5: Some("zzz"))
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [local], Error("unused"))
  process.send(sut, reconciler.SeedMirror("root", []))
  let assert [UploadDispatched(_)] = receive_transfers(dispatches, 1)

  // What the pool does on success: record the known state, then settle with
  // the uploaded file's sighting.
  process.send(
    owner,
    state_owner.PutKnown(KnownFile(
      file_id: "id-up",
      path: "mine.txt",
      remote_modified_time: "2026-07-22T10:00:00Z",
      md5: Some("zzz"),
      size: 3,
      local_mtime_seconds: 1000,
      kind: Blob,
    )),
  )
  let uploaded =
    RemoteSighting(
      ..a_sighting("id-up", "mine.txt", "root"),
      modified_time: "2026-07-22T10:00:00Z",
      md5: Some("zzz"),
      size: Some(3),
    )
  process.send(sut, reconciler.SettleUpload("mine.txt", Ok(uploaded)))

  assert expect_no_transfers(dispatches)
}

// --- Trash planning -----------------------------------------------------------

pub fn a_locally_deleted_file_is_planned_for_trash_once_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let known =
    KnownFile(
      file_id: "id-1",
      path: "gone.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )
  process.send(owner, state_owner.PutKnown(known))
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "gone.txt", "root")]),
  )

  assert receive_transfers(dispatches, 1) == [TrashDispatched("id-1")]
  process.send(sut, reconciler.ReconcileNow)
  assert expect_no_transfers(dispatches)

  // The pool forgets the known state on success, then settles.
  process.send(owner, state_owner.ForgetKnown("id-1"))
  process.send(sut, reconciler.SettleTrash("id-1", Ok(Nil)))
  assert expect_no_transfers(dispatches)
}

// --- Conflict resolution --------------------------------------------------------

fn a_synced_known(file_id: String, path: String) -> entry.KnownFile {
  KnownFile(
    file_id: file_id,
    path: path,
    remote_modified_time: "2026-07-01T10:00:00Z",
    md5: Some("aaa"),
    size: 42,
    local_mtime_seconds: 1000,
    kind: Blob,
  )
}

pub fn an_edit_edit_conflict_dispatches_a_conflicted_copy_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(a_synced_known("id-1", "report.txt")),
  )
  let edited_local =
    LocalFile(
      path: "report.txt",
      size: 43,
      mtime_seconds: 2000,
      md5: Some("bbb"),
    )
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [edited_local], Error("unused"))
  let edited_remote =
    RemoteSighting(
      ..a_sighting("id-1", "report.txt", "root"),
      md5: Some("ccc"),
      modified_time: "2026-07-02T09:00:00Z",
    )

  process.send(sut, reconciler.SeedMirror("root", [edited_remote]))

  let assert [ConflictCopyDispatched(remote, copy_path)] =
    receive_transfers(dispatches, 1)
  assert remote.file_id == "id-1"
  assert remote.path == "report.txt"
  assert copy_path == "report (conflicted copy 2026-07-22).txt"

  // In flight: rounds must not re-dispatch the same conflict.
  process.send(sut, reconciler.ReconcileNow)
  assert expect_no_transfers(dispatches)
}

fn an_edited_native(policy: entry.NativeDocPolicy, path: String) {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(KnownFile(
      file_id: "id-doc",
      path: path,
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: None,
      size: 42,
      local_mtime_seconds: 1000,
      kind: GoogleNative,
    )),
  )
  let edited = LocalFile(path: path, size: 99, mtime_seconds: 2000, md5: None)
  let dispatches = process.new_subject()
  let sut =
    start_reconciler_with_interval(
      owner,
      dispatches,
      [edited],
      Error("unused"),
      idle_round_interval,
      policy,
      fn() { Error(Nil) },
    )
  let native =
    RemoteSighting(
      ..a_sighting("id-doc", "notes", "root"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
    )
  process.send(sut, reconciler.SeedMirror("root", [native]))
  dispatches
}

// Under an export policy the exported native is a real editable file: a local
// edit is preserved as a conflicted-copy blob (the source Doc re-exports at
// the original path via the same conflict machinery) — never pushed back.
pub fn an_edited_native_export_becomes_a_conflicted_copy_test() {
  let dispatches = an_edited_native(entry.ExportOffice, "notes.docx")

  let assert [ConflictCopyDispatched(remote, copy_path)] =
    receive_transfers(dispatches, 1)
  assert remote.file_id == "id-doc"
  assert remote.path == "notes.docx"
  assert copy_path == "notes (conflicted copy 2026-07-22).docx"
}

// Under LinkFile the local file is a generated .desktop link, not user
// content: an edit is simply overwritten by re-materialising the link.
pub fn an_edited_native_link_is_just_rewritten_test() {
  let dispatches = an_edited_native(entry.LinkFile, "notes.desktop")

  let assert [DownloadDispatched(remote)] = receive_transfers(dispatches, 1)
  assert remote.file_id == "id-doc"
}

pub fn divergent_never_synced_twins_conflict_into_a_copy_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let local =
    LocalFile(path: "report.txt", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  // The on-demand hash disagrees with the remote md5: real divergence.
  let sut = start_reconciler(owner, dispatches, [local], Ok("zzz"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )

  let assert [ConflictCopyDispatched(_, copy_path)] =
    receive_transfers(dispatches, 1)
  assert copy_path == "report (conflicted copy 2026-07-22).txt"
}

pub fn a_local_edit_survives_a_remote_delete_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(a_synced_known("id-1", "report.txt")),
  )
  let edited_local =
    LocalFile(
      path: "report.txt",
      size: 43,
      mtime_seconds: 2000,
      md5: Some("bbb"),
    )
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [edited_local], Error("unused"))

  // Remote side deleted the file; the local edit must win.
  process.send(sut, reconciler.SeedMirror("root", []))

  // Resolution forgets the stale link…
  assert fakes.retry_until(40, fn() {
    process.call(owner, 500, state_owner.GetKnown("id-1", _)) == None
  })
  // …so the next round sees a brand-new local file and uploads it.
  process.send(sut, reconciler.ReconcileNow)
  let assert [UploadDispatched(plan)] = receive_transfers(dispatches, 1)
  assert plan.local.path == "report.txt"
  assert plan.existing_file_id == None
}

pub fn a_remote_edit_survives_a_local_delete_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(a_synced_known("id-1", "report.txt")),
  )
  let dispatches = process.new_subject()
  // No local files: the mirror copy was deleted while the remote changed.
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))
  let edited_remote =
    RemoteSighting(
      ..a_sighting("id-1", "report.txt", "root"),
      md5: Some("ccc"),
      modified_time: "2026-07-02T09:00:00Z",
    )

  process.send(sut, reconciler.SeedMirror("root", [edited_remote]))

  assert fakes.retry_until(40, fn() {
    process.call(owner, 500, state_owner.GetKnown("id-1", _)) == None
  })
  process.send(sut, reconciler.ReconcileNow)
  let assert [DownloadDispatched(remote)] = receive_transfers(dispatches, 1)
  assert remote.file_id == "id-1"
}

// --- Local renames become remote moves ------------------------------------------

pub fn a_local_rename_dispatches_a_remote_move_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(a_synced_known("id-1", "report.txt")),
  )
  // Same size and mtime as the known snapshot, new path: a rename.
  let renamed_local =
    LocalFile(
      path: "docs/renamed.txt",
      size: 42,
      mtime_seconds: 1000,
      md5: None,
    )
  let dispatches = process.new_subject()
  let sut =
    start_reconciler(owner, dispatches, [renamed_local], Error("unused"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [
      a_folder_sighting("id-docs", "docs", "root"),
      a_sighting("id-1", "report.txt", "root"),
    ]),
  )

  // The remote "docs" folder also materialises locally (bookkeeping); the
  // move plan is what this test is about.
  let assert [plan] =
    receive_transfers(dispatches, 2)
    |> list.filter_map(fn(dispatch) {
      case dispatch {
        MoveRemoteDispatched(plan) -> Ok(plan)
        _ -> Error(Nil)
      }
    })
  assert plan.file_id == "id-1"
  assert plan.from_path == "report.txt"
  assert plan.to_path == "docs/renamed.txt"
  assert plan.new_name == "renamed.txt"
  assert plan.old_parent_id == "root"
  assert plan.anchor_parent_id == "id-docs"
  assert plan.missing_folders == []

  // What the pool does with the folder download: record it as known, so
  // rounds stop re-materialising it.
  process.send(
    owner,
    state_owner.PutKnown(
      KnownFile(
        ..a_synced_known("id-docs", "docs"),
        md5: None,
        kind: entry.Folder,
      ),
    ),
  )

  // In flight: no re-dispatch until settled.
  process.send(sut, reconciler.ReconcileNow)
  assert expect_no_transfers(dispatches)
}

pub fn a_rename_candidate_with_different_content_is_not_moved_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(a_synced_known("id-1", "report.txt")),
  )
  // Same size+mtime as the known, but an unrelated file: its on-demand hash
  // disagrees with the known's md5, so it must NOT rename the remote onto
  // it — the old remote trashes and the new file uploads instead.
  let impostor =
    LocalFile(
      path: "docs/renamed.txt",
      size: 42,
      mtime_seconds: 1000,
      md5: None,
    )
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [impostor], Ok("different-md5"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [
      a_folder_sighting("id-docs", "docs", "root"),
      a_sighting("id-1", "report.txt", "root"),
    ]),
  )

  let dispatched = receive_transfers(dispatches, 3)
  assert !list.any(dispatched, fn(d) {
    case d {
      MoveRemoteDispatched(_) -> True
      _ -> False
    }
  })
  assert list.any(dispatched, fn(d) { d == TrashDispatched("id-1") })
  assert list.any(dispatched, fn(d) {
    case d {
      UploadDispatched(plan) -> plan.local.path == "docs/renamed.txt"
      _ -> False
    }
  })
}

pub fn a_settled_remote_move_stops_being_dispatched_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(a_synced_known("id-1", "report.txt")),
  )
  let renamed_local =
    LocalFile(path: "renamed.txt", size: 42, mtime_seconds: 1000, md5: None)
  let dispatches = process.new_subject()
  let sut =
    start_reconciler(owner, dispatches, [renamed_local], Error("unused"))
  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )
  let assert [MoveRemoteDispatched(_)] = receive_transfers(dispatches, 1)

  // What the pool does on success: updated bookkeeping, then the settle
  // carrying the renamed sighting.
  process.send(
    owner,
    state_owner.PutKnown(
      KnownFile(..a_synced_known("id-1", "renamed.txt"), path: "renamed.txt"),
    ),
  )
  let renamed_sighting =
    RemoteSighting(
      ..a_sighting("id-1", "renamed.txt", "root"),
      name: "renamed.txt",
    )
  process.send(sut, reconciler.SettleMove("id-1", Ok(renamed_sighting)))

  assert expect_no_transfers(dispatches)
}

// --- Periodic rounds ----------------------------------------------------------

pub fn rounds_repeat_on_the_configured_interval_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut =
    start_reconciler_with_interval(
      owner,
      dispatches,
      [],
      Error("unused"),
      25,
      LinkFile,
      fn() { Error(Nil) },
    )

  process.send(sut, reconciler.SeedMirror("root", []))

  // One scan per round: the seed's own round plus at least two timer-driven.
  let assert Ok(LocalScanned) = process.receive(dispatches, 1000)
  let assert Ok(LocalScanned) = process.receive(dispatches, 1000)
  let assert Ok(LocalScanned) = process.receive(dispatches, 1000)
  Nil
}

// --- Pool crash recovery (F2) -------------------------------------------------

pub fn a_pool_crash_clears_in_flight_so_stranded_work_redispatches_test() {
  let owner = fakes.start_ephemeral_state_owner()
  // A synced blob that vanished locally: the round decides DeleteRemote and
  // marks its file_id pending_trashes until a settle arrives.
  process.send(
    owner,
    state_owner.PutKnown(KnownFile(
      file_id: "id-1",
      path: "gone.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )),
  )
  let dispatches = process.new_subject()
  let #(pool_pid, pool_name) = start_fake_pool()
  let sut =
    start_reconciler_with_interval(
      owner,
      dispatches,
      [],
      Error("unused"),
      idle_round_interval,
      LinkFile,
      fn() { process.subject_owner(process.named_subject(pool_name)) },
    )

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "gone.txt", "root")]),
  )
  let assert [TrashDispatched("id-1")] = receive_transfers(dispatches, 1)

  // Still pending: a fresh round must NOT re-dispatch the same trash.
  process.send(sut, reconciler.ReconcileNow)
  assert expect_no_transfers(dispatches)

  // The pool dies with the trash in flight — the settle will never arrive.
  // The reconciler's monitor must fire and clear the stranded pending set.
  process.kill(pool_pid)
  process.sleep(100)

  // The next round re-dispatches the work the dead pool never finished.
  process.send(sut, reconciler.ReconcileNow)
  let assert [TrashDispatched("id-1")] = receive_transfers(dispatches, 1)
  Nil
}

fn build_config(
  owner: Subject(state_owner.Command),
  dispatches: Subject(Dispatch),
  scan: fn() -> Result(List(entry.LocalFile), String),
  trouble: Subject(String),
  allow_mass_deletion: Bool,
) -> reconciler.ReconcilerConfig {
  ReconcilerConfig(
    state_owner: owner,
    resolve_pool_pid: fn() { Error(Nil) },
    dispatch_download: fn(remote, _expected) {
      process.send(dispatches, DownloadDispatched(remote))
    },
    dispatch_delete_local: fn(known: entry.KnownFile) {
      process.send(dispatches, DeleteLocalDispatched(known.file_id, known.path))
    },
    dispatch_upload: fn(plan) {
      process.send(dispatches, UploadDispatched(plan))
    },
    dispatch_trash_remote: fn(file_id) {
      process.send(dispatches, TrashDispatched(file_id))
    },
    dispatch_conflict_copy: fn(remote, copy_path) {
      process.send(dispatches, ConflictCopyDispatched(remote, copy_path))
    },
    dispatch_move_local: fn(updated, from) {
      process.send(dispatches, MoveLocalDispatched(updated, from))
    },
    dispatch_move_remote: fn(plan) {
      process.send(dispatches, MoveRemoteDispatched(plan))
    },
    request_seed: fn() { process.send(dispatches, SeedRequested) },
    scan_local: scan,
    hash_local_file: fn(_path) { Ok("aaa") },
    native_policy: LinkFile,
    round_interval_ms: idle_round_interval,
    today: fn() { "2026-07-22" },
    report_trouble: fn(line) { process.send(trouble, line) },
    report_activity: fn(_line) { Nil },
    allow_mass_deletion: allow_mass_deletion,
  )
}

fn start_reconciler_guarded(
  owner: Subject(state_owner.Command),
  dispatches: Subject(Dispatch),
  locals: List(entry.LocalFile),
  trouble: Subject(String),
  allow_mass_deletion: Bool,
) -> Subject(reconciler.Command) {
  let name = process.new_name(prefix: "reconciler_test")
  let assert Ok(_) =
    reconciler.start(
      name,
      build_config(
        owner,
        dispatches,
        fn() { Ok(locals) },
        trouble,
        allow_mass_deletion,
      ),
    )
  process.named_subject(name)
}

// --- mass-deletion valve ---------------------------------------------------
// An unmounted mirror makes the scan return an EMPTY list; a false-empty
// seed makes every known look remote-deleted. Either way a single round
// would wipe one side. The valve suppresses the round's deletions, reports
// once, and keeps everything non-destructive flowing (rclone bisync's
// default-on 50% abort, adapted to a daemon).

fn range_1_to(top: Int) -> List(Int) {
  build_range(top, [])
}

fn build_range(current: Int, acc: List(Int)) -> List(Int) {
  case current < 1 {
    True -> acc
    False -> build_range(current - 1, [current, ..acc])
  }
}

fn twenty_known_files(owner: Subject(state_owner.Command)) -> Nil {
  list.each(range_1_to(20), fn(n) {
    process.send(
      owner,
      state_owner.PutKnown(KnownFile(
        file_id: "id-" <> int.to_string(n),
        path: "file" <> int.to_string(n) <> ".txt",
        remote_modified_time: "2026-07-01T10:00:00Z",
        md5: Some("aaa"),
        size: 42,
        local_mtime_seconds: 1000,
        kind: Blob,
      )),
    )
  })
}

fn twenty_sightings() -> List(reconciler.RemoteSighting) {
  list.map(range_1_to(20), fn(n) {
    a_sighting(
      "id-" <> int.to_string(n),
      "file" <> int.to_string(n) <> ".txt",
      "root-1",
    )
  })
}

pub fn an_empty_scan_cannot_mass_trash_the_drive_test() {
  let owner = fakes.start_ephemeral_state_owner()
  twenty_known_files(owner)
  let dispatches = process.new_subject()
  let trouble = process.new_subject()
  // Locals EMPTY: the unmounted-mirror shape. Without the valve this round
  // dispatches twenty EnqueueTrashRemote.
  let reconciler_subject =
    start_reconciler_guarded(owner, dispatches, [], trouble, False)
  process.send(
    reconciler_subject,
    reconciler.SeedMirror("root-1", twenty_sightings()),
  )

  // One loud line, no destructive dispatch at all.
  let assert Ok(line) = process.receive(trouble, 2000)
  assert line
    == "mass deletion valve: this round would delete 20 of 20 synced files —"
    <> " deletions suppressed (unmounted mirror or empty listing? set"
    <> " IARAGON_ALLOW_MASS_DELETE=1 and restart if this is intended)"
  assert expect_no_transfers(dispatches)
  // Only the FIRST round of the streak reports; the next stays quiet.
  process.send(reconciler_subject, reconciler.ReconcileNow)
  assert process.receive(trouble, 500) == Error(Nil)
}

pub fn the_override_lets_a_mass_deletion_through_test() {
  let owner = fakes.start_ephemeral_state_owner()
  twenty_known_files(owner)
  let dispatches = process.new_subject()
  let trouble = process.new_subject()
  let reconciler_subject =
    start_reconciler_guarded(owner, dispatches, [], trouble, True)
  process.send(
    reconciler_subject,
    reconciler.SeedMirror("root-1", twenty_sightings()),
  )

  let transfers = receive_transfers(dispatches, 20)
  assert list.length(transfers) == 20
  assert process.receive(trouble, 300) == Error(Nil)
}

pub fn a_failed_scan_skips_the_round_instead_of_crashing_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let trouble = process.new_subject()
  let name = process.new_name(prefix: "reconciler_test")
  let assert Ok(_) =
    reconciler.start(
      name,
      build_config(
        owner,
        dispatches,
        fn() { Error("mirror scan exploded") },
        trouble,
        False,
      ),
    )
  let reconciler_subject = process.named_subject(name)
  process.send(
    reconciler_subject,
    reconciler.SeedMirror("root-1", [a_sighting("id-1", "a.txt", "root-1")]),
  )

  // The round is skipped with one line — not an actor crash (which would
  // burn restart budget every 30s while a disk stays unreadable).
  let assert Ok(line) = process.receive(trouble, 2000)
  assert line == "local scan failed: mirror scan exploded — skipping this round"
  assert expect_no_transfers(dispatches)
  assert process.subject_owner(reconciler_subject) != Error(Nil)
  // Still failing on the next round: the streak reported once, stays quiet.
  process.send(reconciler_subject, reconciler.ReconcileNow)
  assert process.receive(trouble, 500) == Error(Nil)
}

pub fn a_materialized_native_never_collides_with_a_sibling_blob_test() {
  // A Doc named `notes` materialises (default policy) as `notes.desktop` —
  // the SAME final path as a sibling blob literally named `notes.desktop`.
  // Materialisation must take part in disambiguation: two fileIds sharing
  // one local path would otherwise overwrite each other locally and then
  // corrupt each other REMOTELY (download-over, then upload-back ping-pong).
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))
  let doc =
    RemoteSighting(
      ..a_sighting("id-doc", "notes", "root"),
      mime_type: "application/vnd.google-apps.document",
      size: None,
      md5: None,
    )
  let blob = a_sighting("id-blob", "notes.desktop", "root")

  process.send(sut, reconciler.SeedMirror("root", [doc, blob]))

  let assert [DownloadDispatched(first), DownloadDispatched(second)] =
    receive_transfers(dispatches, 2)
  assert first.path != second.path
}

pub fn a_stale_timer_tick_is_dropped_without_running_a_round_test() {
  // Timers armed on the actor's NAME survive its crash: a tick from a
  // previous incarnation must die (no round, no re-arm) or every crash
  // would add one everlasting timer chain.
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let sut = start_reconciler(owner, dispatches, [], Error("unused"))

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "a.txt", "root")]),
  )
  // The seed round downloads the file once.
  let assert [DownloadDispatched(_)] = receive_transfers(dispatches, 1)

  // A stale generation (the real one is random and non-negative).
  process.send(sut, reconciler.TickRound(-1))
  assert expect_no_transfers(dispatches)

  // The actor is alive and still reconciles on demand.
  process.send(sut, reconciler.ReconcileNow)
  let assert [DownloadDispatched(_)] = receive_transfers(dispatches, 1)
  Nil
}

pub fn a_late_pool_down_spares_transfers_sent_to_the_new_pool_test() {
  // The pool died and restarted; a round dispatched an upload to the NEW
  // pool before the OLD pool's Down was processed. Clearing that pending
  // would re-dispatch a live transfer — files.create twice — and duplicate
  // the file on Drive. Only entries tagged with the DEAD pid may go.
  let old_pool = process.spawn(fn() { process.sleep(30_000) })
  let new_pool = process.spawn(fn() { process.sleep(30_000) })
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let local =
    LocalFile(path: "mine.txt", size: 3, mtime_seconds: 1000, md5: None)
  let sut =
    start_reconciler_with_interval(
      owner,
      dispatches,
      [local],
      Error("unused"),
      idle_round_interval,
      entry.LinkFile,
      // Dispatches happening now go to (and are tagged with) the NEW pool.
      fn() { Ok(new_pool) },
    )

  process.send(sut, reconciler.SeedMirror("root", []))
  let assert [UploadDispatched(_)] = receive_transfers(dispatches, 1)

  // The OLD pool's Down arrives late: the pending tagged new_pool survives,
  // so the next round does NOT re-dispatch.
  process.send(sut, reconciler.ForgetInFlight(Some(old_pool)))
  process.send(sut, reconciler.ReconcileNow)
  assert expect_no_transfers(dispatches)

  // The NEW pool dying is a real loss: the pending clears and the next
  // round re-dispatches.
  process.send(sut, reconciler.ForgetInFlight(Some(new_pool)))
  process.send(sut, reconciler.ReconcileNow)
  let assert [UploadDispatched(_)] = receive_transfers(dispatches, 1)
  Nil
}

// --- audit trail -----------------------------------------------------------
// One journal line per round that decided work, with per-category counts;
// a workless steady-state round stays silent. This is the trail that was
// missing when ~190 state entries vanished with a two-line log.

pub fn a_working_round_reports_its_workload_test() {
  let owner = fakes.start_ephemeral_state_owner()
  let dispatches = process.new_subject()
  let trouble = process.new_subject()
  let activity = process.new_subject()
  let name = process.new_name(prefix: "reconciler_test")
  let assert Ok(_) =
    reconciler.start(
      name,
      ReconcilerConfig(
        ..build_config(owner, dispatches, fn() { Ok([]) }, trouble, False),
        report_activity: fn(line) { process.send(activity, line) },
      ),
    )
  let sut = process.named_subject(name)

  process.send(
    sut,
    reconciler.SeedMirror("root", [
      a_folder_sighting("id-docs", "docs", "root"),
      a_sighting("id-1", "report.txt", "id-docs"),
    ]),
  )

  let assert Ok(line) = process.receive(activity, 2000)
  assert line == "round: downloads 2"
}

pub fn a_workless_round_stays_silent_test() {
  let owner = fakes.start_ephemeral_state_owner()
  process.send(
    owner,
    state_owner.PutKnown(KnownFile(
      file_id: "id-1",
      path: "report.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )),
  )
  let dispatches = process.new_subject()
  let trouble = process.new_subject()
  let activity = process.new_subject()
  let name = process.new_name(prefix: "reconciler_test")
  let local =
    LocalFile(path: "report.txt", size: 42, mtime_seconds: 1000, md5: None)
  let assert Ok(_) =
    reconciler.start(
      name,
      ReconcilerConfig(
        ..build_config(owner, dispatches, fn() { Ok([local]) }, trouble, False),
        report_activity: fn(line) { process.send(activity, line) },
      ),
    )
  let sut = process.named_subject(name)

  process.send(
    sut,
    reconciler.SeedMirror("root", [a_sighting("id-1", "report.txt", "root")]),
  )

  assert expect_no_transfers(dispatches)
  assert process.receive(activity, 100) == Error(Nil)
}
