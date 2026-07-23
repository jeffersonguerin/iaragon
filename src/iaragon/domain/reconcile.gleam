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
  MoveLocal, MoveRemote, Noop, RemoteEditLocalDelete, UploadLocal,
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
    None, None, Some(k) ->
      case k.kind {
        // The local scan never sees directories, so a folder in this branch
        // only proves the REMOTE side went away: clean up the orphan local
        // directory (the pool removes it only once empty) instead of leaving
        // it behind forever.
        entry.Folder -> DeleteLocal(k.path)
        entry.Blob | entry.GoogleNative | entry.Shortcut(_) ->
          ForgetKnown(k.file_id)
      }
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
      case k.kind {
        // The local scan lists files, never directories: a synced folder
        // always looks locally absent, and that must not read as deleted.
        // (Local deletion of an EMPTY folder therefore does not propagate;
        // its files' deletions do.)
        entry.Folder -> Noop
        entry.Blob | entry.GoogleNative | entry.Shortcut(_) ->
          case detect_remote_change(r, k) {
            False -> DeleteRemote(r.file_id)
            True -> Conflict(k.path, k.file_id, RemoteEditLocalDelete)
          }
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

  let renames = infer_local_renames(locals, remotes, lasts)

  // Known files anchor the join: their file_id claims a remote and their
  // path claims a local file.
  let known_decisions =
    list.map(lasts, fn(k) {
      case dict.get(renames, k.file_id) {
        Ok(to) -> MoveRemote(k.file_id, k.path, to)
        Error(Nil) ->
          reconcile(
            option.from_result(dict.get(local_by_path, k.path)),
            option.from_result(dict.get(remote_by_id, k.file_id)),
            Some(k),
          )
      }
    })
  let renamed_to =
    dict.fold(renames, set.new(), fn(acc, _file_id, to) { set.insert(acc, to) })
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

  // Locals nothing has claimed are brand new on this side — unless they are
  // the destination of an inferred rename.
  let local_decisions =
    locals
    |> list.filter(fn(l) {
      !set.contains(claimed_paths, l.path) && !set.contains(renamed_to, l.path)
    })
    |> list.map(fn(l) { reconcile(Some(l), None, None) })

  [known_decisions, remote_decisions, local_decisions]
  |> list.flatten
  |> list.filter(fn(decision) { decision != Noop })
}

/// Pair vanished knowns (local gone, remote untouched and unmoved) with new
/// locals (no known, no remote at their path) by the cheap signature that a
/// `mv` preserves: size + mtime. Only UNIQUE one-to-one signature matches
/// count — anything ambiguous falls back to delete-plus-create, which is
/// always safe, just wasteful. When both sides carry an md5 the checksum is
/// authoritative (see `content_compatible`), so the caller can hash the
/// candidate locals to reject unrelated files that merely collide on the
/// signature. Public so the application can do exactly that before the
/// second, authoritative pass in `reconcile_all`. Returns file_id → new path.
pub fn infer_local_renames(
  locals: List(LocalFile),
  remotes: List(RemoteFile),
  lasts: List(KnownFile),
) -> dict.Dict(String, String) {
  let local_by_path =
    list.fold(locals, dict.new(), fn(acc, l) { dict.insert(acc, l.path, l) })
  let remote_by_id =
    list.fold(remotes, dict.new(), fn(acc, r) { dict.insert(acc, r.file_id, r) })
  let known_paths =
    list.fold(lasts, set.new(), fn(acc, k) { set.insert(acc, k.path) })
  let remote_paths =
    list.fold(remotes, set.new(), fn(acc, r) {
      case r.trashed {
        True -> acc
        False -> set.insert(acc, r.path)
      }
    })

  let vanished =
    list.filter(lasts, fn(k) {
      // Folders are never rename candidates: the scan lists files only, so a
      // synced folder ALWAYS looks locally vanished, and pairing it with a
      // fresh file of matching (size, mtime) would rename the whole remote
      // folder onto that file.
      k.kind != entry.Folder
      && !dict.has_key(local_by_path, k.path)
      && case dict.get(remote_by_id, k.file_id) {
        Ok(r) -> !r.trashed && r.path == k.path && !detect_remote_change(r, k)
        Error(Nil) -> False
      }
    })
  let fresh_locals =
    list.filter(locals, fn(l) {
      !set.contains(known_paths, l.path) && !set.contains(remote_paths, l.path)
    })

  let vanished_by_signature =
    list.fold(vanished, dict.new(), fn(acc, k) {
      collect_by_signature(acc, #(k.size, k.local_mtime_seconds), k)
    })
  let fresh_by_signature =
    list.fold(fresh_locals, dict.new(), fn(acc, l) {
      collect_by_signature(acc, #(l.size, l.mtime_seconds), l)
    })

  dict.fold(vanished_by_signature, dict.new(), fn(acc, signature, knowns) {
    case knowns, dict.get(fresh_by_signature, signature) {
      [known], Ok([local]) ->
        case content_compatible(known, local) {
          True -> dict.insert(acc, known.file_id, local.path)
          // Same cheap signature, but the checksums prove different content:
          // an unrelated file that merely collided. Fall back to
          // delete-plus-create (the caller hashes candidates so this md5 is
          // present; without it the size+mtime match stands).
          False -> acc
        }
      _, _ -> acc
    }
  })
}

fn content_compatible(known: KnownFile, local: LocalFile) -> Bool {
  case known.md5, local.md5 {
    Some(known_md5), Some(local_md5) -> known_md5 == local_md5
    _, _ -> True
  }
}

fn collect_by_signature(
  acc: dict.Dict(#(Int, Int), List(a)),
  signature: #(Int, Int),
  value: a,
) -> dict.Dict(#(Int, Int), List(a)) {
  dict.upsert(acc, signature, fn(existing) {
    case existing {
      Some(values) -> [value, ..values]
      None -> [value]
    }
  })
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
