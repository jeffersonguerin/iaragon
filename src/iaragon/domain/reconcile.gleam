//// The correctness-critical core: a PURE three-way diff between the local
//// state, the remote state, and the last known synced state of one file.
////
//// The match on presence is exhaustive by construction — no `_` catch-all at
//// the presence level. An unhandled combination must be a compile error,
//// because an unhandled combination at runtime is silent data loss.

import gleam/option.{type Option, None, Some}
import iaragon/domain/decision.{
  type SyncDecision, Conflict, DownloadRemote, EditEdit, ForgetKnown, Noop,
  UploadLocal,
}
import iaragon/domain/entry.{type KnownFile, type LocalFile, type RemoteFile}

pub fn reconcile(
  local: Option(LocalFile),
  remote: Option(RemoteFile),
  last: Option(KnownFile),
) -> SyncDecision {
  case local, remote, last {
    None, None, None -> Noop
    Some(l), None, None -> UploadLocal(l.path)
    None, Some(r), None -> DownloadRemote(r.file_id, r.path)
    None, None, Some(k) -> ForgetKnown(k.file_id)
    Some(_l), Some(_r), None -> todo as "both created, no last known state"
    Some(_l), None, Some(_k) -> todo as "remote gone"
    None, Some(_r), Some(_k) -> todo as "local gone"
    Some(l), Some(r), Some(k) ->
      case detect_local_change(l, k), detect_remote_change(r, k) {
        False, False -> Noop
        True, False -> UploadLocal(l.path)
        False, True -> DownloadRemote(r.file_id, k.path)
        True, True ->
          case share_same_content(l, r) {
            True -> Noop
            False -> Conflict(k.path, k.file_id, EditEdit)
          }
      }
  }
}

/// Cheap metadata first (size + mtime); when both sides carry an md5 it is
/// authoritative, so a bare `touch` does not count as a change.
fn detect_local_change(local: LocalFile, last: KnownFile) -> Bool {
  case local.md5, last.md5 {
    Some(local_md5), Some(last_md5) -> local_md5 != last_md5
    _, _ ->
      local.size != last.size
      || local.mtime_seconds != last.local_mtime_seconds
  }
}

/// Blobs carry an md5 on Drive, which is authoritative. Google-native files
/// have no checksum at all (verified Drive API v3 fact), so their only change
/// signal is `modifiedTime`.
fn detect_remote_change(remote: RemoteFile, last: KnownFile) -> Bool {
  case remote.md5, last.md5 {
    Some(remote_md5), Some(last_md5) -> remote_md5 != last_md5
    _, _ -> remote.modified_time != last.remote_modified_time
  }
}

/// Both sides changed, but to identical bytes: only provably identical
/// content (matching checksums) avoids the conflict.
fn share_same_content(local: LocalFile, remote: RemoteFile) -> Bool {
  case local.md5, remote.md5 {
    Some(local_md5), Some(remote_md5) -> local_md5 == remote_md5
    _, _ -> False
  }
}
