import gleam/option.{None, Some}
import iaragon/domain/decision.{
  BothCreated, Conflict, DeleteLocal, DeleteRemote, DownloadRemote, EditEdit,
  ForgetKnown, LocalEditRemoteDelete, Noop, RemoteEditLocalDelete, UploadLocal,
}
import iaragon/domain/entry.{Blob, GoogleNative, KnownFile, LocalFile, RemoteFile}
import iaragon/domain/reconcile

// --- Test data builders -----------------------------------------------------
//
// A consistent trio: a blob file that was synced once, unchanged on both
// sides. Individual tests derive modified/deleted variants from these.

fn a_local() -> entry.LocalFile {
  LocalFile(path: "docs/report.txt", size: 42, mtime_seconds: 1000, md5: Some("aaa"))
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

// --- Change detection with all three present --------------------------------

pub fn unchanged_everywhere_noops_test() {
  assert reconcile.reconcile(Some(a_local()), Some(a_remote()), Some(a_known()))
    == Noop
}

pub fn modified_only_locally_uploads_test() {
  let local = LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  assert reconcile.reconcile(Some(local), Some(a_remote()), Some(a_known()))
    == UploadLocal("docs/report.txt")
}

pub fn modified_only_remotely_downloads_test() {
  let remote =
    RemoteFile(..a_remote(), md5: Some("ccc"), modified_time: "2026-07-02T09:00:00Z")
  assert reconcile.reconcile(Some(a_local()), Some(remote), Some(a_known()))
    == DownloadRemote("id-1", "docs/report.txt")
}

pub fn modified_on_both_sides_conflicts_test() {
  let local = LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  let remote =
    RemoteFile(..a_remote(), md5: Some("ccc"), modified_time: "2026-07-02T09:00:00Z")
  assert reconcile.reconcile(Some(local), Some(remote), Some(a_known()))
    == Conflict("docs/report.txt", "id-1", EditEdit)
}

pub fn modified_on_both_sides_to_same_content_noops_test() {
  let local = LocalFile(..a_local(), size: 50, mtime_seconds: 2000, md5: Some("ddd"))
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
  let local = LocalFile(..a_local(), size: 43, mtime_seconds: 2000, md5: Some("bbb"))
  assert reconcile.reconcile(Some(local), None, Some(a_known()))
    == Conflict("docs/report.txt", "id-1", LocalEditRemoteDelete)
}

pub fn remote_edit_with_local_delete_conflicts_test() {
  let remote =
    RemoteFile(..a_remote(), md5: Some("ccc"), modified_time: "2026-07-02T09:00:00Z")
  assert reconcile.reconcile(None, Some(remote), Some(a_known()))
    == Conflict("docs/report.txt", "id-1", RemoteEditLocalDelete)
}

pub fn trashed_remote_of_unknown_file_noops_test() {
  // A file we never synced got trashed remotely: nothing to mirror, nothing
  // to forget.
  let remote = RemoteFile(..a_remote(), trashed: True)
  assert reconcile.reconcile(None, Some(remote), None) == Noop
}

// --- Both created without a last known state ---------------------------------

pub fn both_created_with_identical_content_noops_test() {
  // First run over a pre-populated mirror: adopt silently, no transfer.
  assert reconcile.reconcile(Some(a_local()), Some(a_remote()), None) == Noop
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
