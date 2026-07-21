//// The outcome of reconciling one file across the three-way diff. Every
//// constructor is an intention verb: the decision says what must be done,
//// not what the world looks like.

pub type ConflictKind {
  EditEdit
  LocalEditRemoteDelete
  RemoteEditLocalDelete
  BothCreated
}

pub type SyncDecision {
  UploadLocal(path: String)
  DownloadRemote(file_id: String, path: String)
  DeleteLocal(path: String)
  DeleteRemote(file_id: String)
  Conflict(path: String, file_id: String, kind: ConflictKind)
  /// Both sides are gone: drop the stale entry from the sync index so the
  /// state table does not leak.
  ForgetKnown(file_id: String)
  Noop
}
