//// The outcome of reconciling one file across the three-way diff. Every
//// constructor is an intention verb: the decision says what must be done,
//// not what the world looks like.

pub type ConflictKind {
  EditEdit
  LocalEditRemoteDelete
  RemoteEditLocalDelete
  BothCreated
  /// A Google-native's local export was edited. Its content cannot be pushed
  /// back (importing a doc into an existing native replaces/converts it — not
  /// safe on the documented API), so the edit is preserved by policy: under an
  /// export policy it becomes a conflicted-copy blob while the remote re-
  /// exports at the original path; under LinkFile the generated link is just
  /// rewritten.
  NativeLocalEdit
}

pub type SyncDecision {
  UploadLocal(path: String)
  DownloadRemote(file_id: String, path: String)
  DeleteLocal(path: String)
  DeleteRemote(file_id: String)
  /// The remote file was renamed or moved: relocate the mirror copy. Any
  /// simultaneous content change is picked up on the round after the move.
  MoveLocal(file_id: String, from: String, to: String)
  /// The LOCAL file was renamed or moved (inferred by pairing a vanished
  /// known with an identical-looking new local): rename the remote file
  /// instead of re-uploading its bytes.
  MoveRemote(file_id: String, from: String, to: String)
  Conflict(path: String, file_id: String, kind: ConflictKind)
  /// Both sides are gone: drop the stale entry from the sync index so the
  /// state table does not leak.
  ForgetKnown(file_id: String)
  /// Never-synced twins with provably identical content: record the link,
  /// transfer nothing. Without the record every round re-hashes the pair.
  AdoptKnown(file_id: String, path: String)
  Noop
}
