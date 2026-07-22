import gleam/list
import gleam/option.{None, Some}
import iaragon/domain/decision.{
  AdoptKnown, BothCreated, Conflict, DeleteLocal, DeleteRemote, DownloadRemote,
  EditEdit, ForgetKnown, LocalEditRemoteDelete, MoveLocal, MoveRemote, Noop,
  RemoteEditLocalDelete, UploadLocal,
}
import iaragon/domain/entry.{
  Blob, GoogleNative, KnownFile, LocalFile, RemoteFile,
}
import iaragon/domain/reconcile

// --- Test data builders -----------------------------------------------------
//
// A consistent trio: a blob file that was synced once, unchanged on both
// sides. Individual tests derive modified/deleted variants from these.

fn a_local() -> entry.LocalFile {
  LocalFile(
    path: "docs/report.txt",
    size: 42,
    mtime_seconds: 1000,
    md5: Some("aaa"),
  )
}

fn a_remote() -> entry.RemoteFile {
  RemoteFile(
    file_id: "id-1",
    name: "report.txt",
    path: "docs/report.txt",
    mime_type: "text/plain",
    parent_id: Some("id-docs"),
    modified_time: "2026-07-01T10:00:00Z",
    size: Some(42),
    md5: Some("aaa"),
    trashed: False,
    kind: Blob,
  )
}

fn a_known() -> entry.KnownFile {
  KnownFile(
    file_id: "id-1",
    path: "docs/report.txt",
    remote_modified_time: "2026-07-01T10:00:00Z",
    md5: Some("aaa"),
    size: 42,
    local_mtime_seconds: 1000,
    kind: Blob,
  )
}

// --- Presence-only cases ----------------------------------------------------

pub fn new_local_file_uploads_test() {
  assert reconcile.reconcile(Some(a_local()), None, None)
    == UploadLocal("docs/report.txt")
}

pub fn new_remote_file_downloads_test() {
  assert reconcile.reconcile(None, Some(a_remote()), None)
    == DownloadRemote("id-1", "docs/report.txt")
}

pub fn gone_on_both_sides_forgets_known_test() {
  assert reconcile.reconcile(None, None, Some(a_known())) == ForgetKnown("id-1")
}

pub fn absent_everywhere_noops_test() {
  assert reconcile.reconcile(None, None, None) == Noop
}

pub fn a_remote_deleted_folder_clears_the_local_directory_test() {
  // The scan never sees directories, so "gone on both sides" of a folder
  // only proves the remote side went away: the orphan local directory must
  // be cleaned up, not just forgotten.
  let folder_known =
    KnownFile(
      ..a_known(),
      file_id: "id-docs",
      path: "docs",
      md5: None,
      kind: entry.Folder,
    )
  assert reconcile.reconcile(None, None, Some(folder_known))
    == DeleteLocal("docs")
}

// --- Change detection with all three present --------------------------------

pub fn unchanged_everywhere_noops_test() {
  assert reconcile.reconcile(Some(a_local()), Some(a_remote()), Some(a_known()))
    == Noop
}

pub fn modified_only_locally_uploads_test() {
  let local =
    LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  assert reconcile.reconcile(Some(local), Some(a_remote()), Some(a_known()))
    == UploadLocal("docs/report.txt")
}

pub fn modified_only_remotely_downloads_test() {
  let remote =
    RemoteFile(
      ..a_remote(),
      md5: Some("ccc"),
      modified_time: "2026-07-02T09:00:00Z",
    )
  assert reconcile.reconcile(Some(a_local()), Some(remote), Some(a_known()))
    == DownloadRemote("id-1", "docs/report.txt")
}

pub fn modified_on_both_sides_conflicts_test() {
  let local =
    LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  let remote =
    RemoteFile(
      ..a_remote(),
      md5: Some("ccc"),
      modified_time: "2026-07-02T09:00:00Z",
    )
  assert reconcile.reconcile(Some(local), Some(remote), Some(a_known()))
    == Conflict("docs/report.txt", "id-1", EditEdit)
}

pub fn modified_on_both_sides_to_same_content_noops_test() {
  let local =
    LocalFile(..a_local(), size: 50, mtime_seconds: 2000, md5: Some("ddd"))
  let remote =
    RemoteFile(
      ..a_remote(),
      size: Some(50),
      md5: Some("ddd"),
      modified_time: "2026-07-02T09:00:00Z",
    )
  assert reconcile.reconcile(Some(local), Some(remote), Some(a_known())) == Noop
}

pub fn touched_local_file_with_same_content_noops_test() {
  // mtime changed but the bytes did not (e.g. `touch`): md5 breaks the tie.
  let local = LocalFile(..a_local(), mtime_seconds: 2000)
  assert reconcile.reconcile(Some(local), Some(a_remote()), Some(a_known()))
    == Noop
}

// --- Deletions ---------------------------------------------------------------

pub fn deleted_locally_propagates_delete_remote_test() {
  assert reconcile.reconcile(None, Some(a_remote()), Some(a_known()))
    == DeleteRemote("id-1")
}

pub fn deleted_remotely_propagates_delete_local_test() {
  assert reconcile.reconcile(Some(a_local()), None, Some(a_known()))
    == DeleteLocal("docs/report.txt")
}

pub fn trashed_remotely_counts_as_remote_delete_test() {
  // Verified Drive API v3 fact: trashing arrives as an ordinary change with
  // file.trashed=true, not as removed=true. The domain treats it as absence.
  let remote = RemoteFile(..a_remote(), trashed: True)
  assert reconcile.reconcile(Some(a_local()), Some(remote), Some(a_known()))
    == DeleteLocal("docs/report.txt")
}

pub fn local_edit_with_remote_delete_conflicts_test() {
  let local =
    LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  assert reconcile.reconcile(Some(local), None, Some(a_known()))
    == Conflict("docs/report.txt", "id-1", LocalEditRemoteDelete)
}

pub fn remote_edit_with_local_delete_conflicts_test() {
  let remote =
    RemoteFile(
      ..a_remote(),
      md5: Some("ccc"),
      modified_time: "2026-07-02T09:00:00Z",
    )
  assert reconcile.reconcile(None, Some(remote), Some(a_known()))
    == Conflict("docs/report.txt", "id-1", RemoteEditLocalDelete)
}

pub fn a_synced_folder_is_not_deleted_for_being_unscannable_test() {
  // The local scan lists files, never directories: a synced folder always
  // looks locally absent. That must NOT read as "deleted locally".
  let folder_remote =
    RemoteFile(
      ..a_remote(),
      file_id: "id-docs",
      name: "docs",
      path: "docs",
      mime_type: "application/vnd.google-apps.folder",
      size: None,
      md5: None,
      kind: entry.Folder,
    )
  let folder_known =
    KnownFile(
      ..a_known(),
      file_id: "id-docs",
      path: "docs",
      md5: None,
      kind: entry.Folder,
    )
  assert reconcile.reconcile(None, Some(folder_remote), Some(folder_known))
    == Noop
}

pub fn trashed_remote_of_unknown_file_noops_test() {
  // A file we never synced got trashed remotely: nothing to mirror, nothing
  // to forget.
  let remote = RemoteFile(..a_remote(), trashed: True)
  assert reconcile.reconcile(None, Some(remote), None) == Noop
}

// --- Remote renames and moves --------------------------------------------------

pub fn a_remote_rename_moves_the_local_copy_test() {
  // Same content, new resolved path: the mirror must move the file, not
  // ignore it (and certainly not re-download it).
  let renamed =
    RemoteFile(..a_remote(), name: "renamed.txt", path: "docs/renamed.txt")
  assert reconcile.reconcile(Some(a_local()), Some(renamed), Some(a_known()))
    == MoveLocal("id-1", "docs/report.txt", "docs/renamed.txt")
}

pub fn a_remote_move_with_a_content_change_moves_first_test() {
  // Move now; the content diff is picked up on the next round, once the
  // known path has caught up.
  let moved =
    RemoteFile(
      ..a_remote(),
      path: "elsewhere/report.txt",
      md5: Some("ccc"),
      modified_time: "2026-07-02T09:00:00Z",
    )
  assert reconcile.reconcile(Some(a_local()), Some(moved), Some(a_known()))
    == MoveLocal("id-1", "docs/report.txt", "elsewhere/report.txt")
}

// --- Both created without a last known state ---------------------------------

pub fn both_created_with_identical_content_is_adopted_test() {
  // First run over a pre-populated mirror: no transfer, but the twin link
  // must be RECORDED — otherwise every round re-hashes the pair.
  assert reconcile.reconcile(Some(a_local()), Some(a_remote()), None)
    == AdoptKnown("id-1", "docs/report.txt")
}

pub fn both_created_with_different_content_conflicts_test() {
  let local = LocalFile(..a_local(), md5: Some("zzz"))
  assert reconcile.reconcile(Some(local), Some(a_remote()), None)
    == Conflict("docs/report.txt", "id-1", BothCreated)
}

pub fn both_created_without_local_checksum_conflicts_test() {
  // Without a checksum we cannot prove the copies are identical; guessing
  // "same" here would silently overwrite one of them.
  let local = LocalFile(..a_local(), md5: None)
  assert reconcile.reconcile(Some(local), Some(a_remote()), None)
    == Conflict("docs/report.txt", "id-1", BothCreated)
}

// --- Google-native files are download-only -----------------------------------

fn a_native_remote() -> entry.RemoteFile {
  RemoteFile(
    ..a_remote(),
    file_id: "id-doc",
    name: "notes",
    path: "docs/notes",
    mime_type: "application/vnd.google-apps.document",
    size: None,
    md5: None,
    kind: GoogleNative,
  )
}

fn a_native_known() -> entry.KnownFile {
  KnownFile(
    ..a_known(),
    file_id: "id-doc",
    path: "docs/notes",
    md5: None,
    kind: GoogleNative,
  )
}

pub fn native_edited_locally_never_uploads_test() {
  // Exports are lossy and capped at 10 MB; uploading a local edit back would
  // destroy the source document. The mirror self-heals by re-downloading.
  let local =
    LocalFile(path: "docs/notes", size: 99, mtime_seconds: 2000, md5: None)
  assert reconcile.reconcile(
      Some(local),
      Some(a_native_remote()),
      Some(a_native_known()),
    )
    == DownloadRemote("id-doc", "docs/notes")
}

pub fn native_edited_remotely_downloads_test() {
  let remote =
    RemoteFile(..a_native_remote(), modified_time: "2026-07-02T09:00:00Z")
  let local =
    LocalFile(path: "docs/notes", size: 42, mtime_seconds: 1000, md5: None)
  assert reconcile.reconcile(Some(local), Some(remote), Some(a_native_known()))
    == DownloadRemote("id-doc", "docs/notes")
}

pub fn native_edited_on_both_sides_downloads_without_conflict_test() {
  // Natives are download-only: the remote copy is authoritative by policy,
  // so there is no edit-edit conflict to surface.
  let remote =
    RemoteFile(..a_native_remote(), modified_time: "2026-07-02T09:00:00Z")
  let local =
    LocalFile(path: "docs/notes", size: 99, mtime_seconds: 2000, md5: None)
  assert reconcile.reconcile(Some(local), Some(remote), Some(a_native_known()))
    == DownloadRemote("id-doc", "docs/notes")
}

pub fn native_created_on_both_sides_downloads_test() {
  // A local file already sits where a never-synced native doc must land:
  // natives cannot round-trip, so the remote wins and gets re-materialised.
  let local =
    LocalFile(path: "docs/notes", size: 99, mtime_seconds: 2000, md5: None)
  assert reconcile.reconcile(Some(local), Some(a_native_remote()), None)
    == DownloadRemote("id-doc", "docs/notes")
}

pub fn native_untouched_noops_test() {
  let local =
    LocalFile(path: "docs/notes", size: 42, mtime_seconds: 1000, md5: None)
  assert reconcile.reconcile(
      Some(local),
      Some(a_native_remote()),
      Some(a_native_known()),
    )
    == Noop
}

// --- reconcile_all: local renames inferred as remote moves --------------------

pub fn a_local_rename_becomes_a_remote_move_test() {
  // The file vanished from its known path and an identical-looking local
  // (same size, same mtime — `mv` preserves both) appeared elsewhere:
  // that is a rename, not delete-plus-create.
  let renamed_local = LocalFile(..a_local(), path: "docs/renamed.txt")
  assert reconcile.reconcile_all([renamed_local], [a_remote()], [a_known()])
    == [MoveRemote("id-1", "docs/report.txt", "docs/renamed.txt")]
}

pub fn an_ambiguous_rename_falls_back_to_delete_and_create_test() {
  // Two identical-looking new locals: no way to tell which one is the
  // rename. Fall back to the safe behaviour.
  let candidate_a = LocalFile(..a_local(), path: "a.txt")
  let candidate_b = LocalFile(..a_local(), path: "b.txt")
  let decisions =
    reconcile.reconcile_all([candidate_a, candidate_b], [a_remote()], [
      a_known(),
    ])
  assert list.contains(decisions, DeleteRemote("id-1"))
  assert list.contains(decisions, UploadLocal("a.txt"))
  assert list.contains(decisions, UploadLocal("b.txt"))
}

pub fn a_signature_mismatch_is_not_a_rename_test() {
  let different = LocalFile(..a_local(), path: "docs/renamed.txt", size: 99)
  let decisions =
    reconcile.reconcile_all([different], [a_remote()], [a_known()])
  assert list.contains(decisions, DeleteRemote("id-1"))
  assert list.contains(decisions, UploadLocal("docs/renamed.txt"))
}

pub fn a_rename_with_a_remote_edit_is_not_inferred_test() {
  // The remote side changed while the local file moved: keep the existing
  // conservative path (edit survives via the conflict machinery).
  let renamed_local = LocalFile(..a_local(), path: "docs/renamed.txt")
  let edited_remote =
    RemoteFile(
      ..a_remote(),
      md5: Some("ccc"),
      modified_time: "2026-07-02T09:00:00Z",
    )
  let decisions =
    reconcile.reconcile_all([renamed_local], [edited_remote], [a_known()])
  assert !list.contains(
    decisions,
    MoveRemote("id-1", "docs/report.txt", "docs/renamed.txt"),
  )
}

// --- reconcile_all: joining the three collections ----------------------------

pub fn reconcile_all_of_fully_synced_state_decides_nothing_test() {
  assert reconcile.reconcile_all([a_local()], [a_remote()], [a_known()]) == []
}

pub fn reconcile_all_joins_known_files_by_id_and_path_test() {
  // The known trio, locally modified: must be joined into ONE decision, not
  // seen as an orphan local plus an orphan remote.
  let local =
    LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  assert reconcile.reconcile_all([local], [a_remote()], [a_known()])
    == [UploadLocal("docs/report.txt")]
}

pub fn reconcile_all_pairs_never_synced_twins_by_path_test() {
  // A never-synced local and a never-synced remote at the same path must be
  // joined into one both-created reconciliation, not upload + download.
  let local =
    LocalFile(path: "b.txt", size: 1, mtime_seconds: 1, md5: Some("zzz"))
  let remote =
    RemoteFile(..a_remote(), file_id: "id-2", name: "b.txt", path: "b.txt")
  assert reconcile.reconcile_all([local], [remote], [])
    == [Conflict("b.txt", "id-2", BothCreated)]
}

pub fn reconcile_all_covers_orphans_on_every_side_test() {
  let modified_known =
    LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  let new_local =
    LocalFile(path: "new.txt", size: 1, mtime_seconds: 1, md5: Some("nnn"))
  let new_remote =
    RemoteFile(..a_remote(), file_id: "id-2", name: "b.txt", path: "b.txt")
  let stale_known = KnownFile(..a_known(), file_id: "id-3", path: "gone.txt")
  assert reconcile.reconcile_all(
      [modified_known, new_local],
      [a_remote(), new_remote],
      [a_known(), stale_known],
    )
    == [
      UploadLocal("docs/report.txt"),
      ForgetKnown("id-3"),
      DownloadRemote("id-2", "b.txt"),
      UploadLocal("new.txt"),
    ]
}
