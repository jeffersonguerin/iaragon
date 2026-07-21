import gleam/option.{None, Some}
import iaragon/domain/decision.{
  DownloadRemote, ForgetKnown, Noop, UploadLocal,
}
import iaragon/domain/entry.{Blob, KnownFile, LocalFile, RemoteFile}
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
