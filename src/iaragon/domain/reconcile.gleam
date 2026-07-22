//// The correctness-critical core: a PURE three-way diff between the local
//// state, the remote state, and the last known synced state of one file.
////
//// The match on presence is exhaustive by construction — no `_` catch-all at
//// the presence level. An unhandled combination must be a compile error,
//// because an unhandled combination at runtime is silent data loss.

import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import iaragon/domain/decision.{
  type SyncDecision, AdoptKnown, BothCreated, Conflict, DeleteLocal,
  DeleteRemote, DownloadRemote, EditEdit, ForgetKnown, LocalEditRemoteDelete,
  MoveLocal, Noop, RemoteEditLocalDelete, UploadLocal,
}
import iaragon/domain/entry.{type KnownFile, type LocalFile, type RemoteFile}

pub fn reconcile(
  local: Option(LocalFile),
  remote: Option(RemoteFile),
  last: Option(KnownFile),
) -> SyncDecision {
  // Trashing arrives from the Changes API as an ordinary change with
  // trashed=true (removed=true is only for permanent deletion / lost access),
  // so a trashed remote is reconciled as an absent remote.
  let remote = case remote {
    Some(r) ->
      case r.trashed {
        True -> None
        False -> Some(r)
      }
    None -> None
  }
  case local, remote, last {
    None, None, None -> Noop
    Some(l), None, None -> UploadLocal(l.path)
    None, Some(r), None -> DownloadRemote(r.file_id, r.path)
    None, None, Some(k) -> ForgetKnown(k.file_id)
    Some(l), Some(r), None ->
      case r.kind {
        // Natives cannot round-trip (no bytes, lossy export), so the remote
        // copy is authoritative and gets re-materialised over the local one.
        entry.GoogleNative -> DownloadRemote(r.file_id, r.path)
        entry.Blob | entry.Folder | entry.Shortcut(_) ->
          case share_same_content(l, r) {
            True -> AdoptKnown(r.file_id, r.path)
            False -> Conflict(l.path, r.file_id, BothCreated)
          }
      }
    Some(l), None, Some(k) ->
      case detect_local_change(l, k) {
        False -> DeleteLocal(k.path)
        True -> Conflict(k.path, k.file_id, LocalEditRemoteDelete)
      }
    None, Some(r), Some(k) ->
      case detect_remote_change(r, k) {
        False -> DeleteRemote(r.file_id)
        True -> Conflict(k.path, k.file_id, RemoteEditLocalDelete)
      }
    Some(l), Some(r), Some(k) ->
      case r.path != k.path {
        // A rename/move on the remote side: relocate the mirror copy first;
        // content diffs surface on the next round, against the new path.
        True -> MoveLocal(k.file_id, k.path, r.path)
        False -> reconcile_in_place(l, r, k)
      }
  }
}

fn reconcile_in_place(
  l: LocalFile,
  r: RemoteFile,
  k: KnownFile,
) -> SyncDecision {
  case r.kind {
    // Download-only by policy: a local edit of a native is never
    // uploaded (it would destroy the source document); the mirror
    // self-heals by re-downloading whenever either side moved.
    entry.GoogleNative ->
      case detect_local_change(l, k), detect_remote_change(r, k) {
        False, False -> Noop
        _, _ -> DownloadRemote(r.file_id, k.path)
      }
    entry.Blob | entry.Folder | entry.Shortcut(_) ->
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

/// Reconcile whole snapshots: join the three collections into per-file
/// trios — known files by (file_id, path), never-synced twins by path — and
/// reconcile each one. Pure, like everything in this module. `Noop`s are
/// dropped: the result is the list of actions to take.
pub fn reconcile_all(
  locals: List(LocalFile),
  remotes: List(RemoteFile),
  lasts: List(KnownFile),
) -> List(SyncDecision) {
  let local_by_path =
    list.fold(locals, dict.new(), fn(acc, l) { dict.insert(acc, l.path, l) })
  let remote_by_id =
    list.fold(remotes, dict.new(), fn(acc, r) { dict.insert(acc, r.file_id, r) })

  // Known files anchor the join: their file_id claims a remote and their
  // path claims a local file.
  let known_decisions =
    list.map(lasts, fn(k) {
      reconcile(
        option.from_result(dict.get(local_by_path, k.path)),
        option.from_result(dict.get(remote_by_id, k.file_id)),
        Some(k),
      )
    })
  let claimed_paths =
    list.fold(lasts, set.new(), fn(acc, k) { set.insert(acc, k.path) })
  let claimed_ids =
    list.fold(lasts, set.new(), fn(acc, k) { set.insert(acc, k.file_id) })

  // Remotes nobody knows yet: a local file already sitting at the same path
  // is their never-synced twin, and that path is thereby claimed too.
  let orphan_remotes =
    list.filter(remotes, fn(r) { !set.contains(claimed_ids, r.file_id) })
  let remote_decisions =
    list.map(orphan_remotes, fn(r) {
      case set.contains(claimed_paths, r.path) {
        True -> reconcile(None, Some(r), None)
        False ->
          reconcile(
            option.from_result(dict.get(local_by_path, r.path)),
            Some(r),
            None,
          )
      }
    })
  let claimed_paths =
    list.fold(orphan_remotes, claimed_paths, fn(acc, r) {
      set.insert(acc, r.path)
    })

  // Locals nothing has claimed are brand new on this side.
  let local_decisions =
    locals
    |> list.filter(fn(l) { !set.contains(claimed_paths, l.path) })
    |> list.map(fn(l) { reconcile(Some(l), None, None) })

  [known_decisions, remote_decisions, local_decisions]
  |> list.flatten
  |> list.filter(fn(decision) { decision != Noop })
}

/// Cheap metadata first (size + mtime); when both sides carry an md5 it is
/// authoritative, so a bare `touch` does not count as a change.
fn detect_local_change(local: LocalFile, last: KnownFile) -> Bool {
  case local.md5, last.md5 {
    Some(local_md5), Some(last_md5) -> local_md5 != last_md5
    _, _ ->
      local.size != last.size || local.mtime_seconds != last.local_mtime_seconds
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
