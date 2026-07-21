//// The correctness-critical core: a PURE three-way diff between the local
//// state, the remote state, and the last known synced state of one file.
////
//// The match on presence is exhaustive by construction — no `_` catch-all at
//// the presence level. An unhandled combination must be a compile error,
//// because an unhandled combination at runtime is silent data loss.

import gleam/option.{type Option, None, Some}
import iaragon/domain/decision.{
  type SyncDecision, DownloadRemote, ForgetKnown, Noop, UploadLocal,
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
    Some(_l), Some(_r), Some(_k) -> todo as "present on both sides"
  }
}
