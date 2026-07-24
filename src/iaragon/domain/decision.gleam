//// The outcome of reconciling one file across the three-way diff. Every
//// constructor is an intention verb: the decision says what must be done,
//// not what the world looks like.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

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

/// The audit line for a round: per-category counts of the decided work,
/// nonzero categories only — `None` when the round decided nothing, so
/// steady state (a round every 30 s) never spams the journal. Pure over the
/// decision list; the caller owns where the line goes.
pub fn describe_workload(decisions: List(SyncDecision)) -> Option(String) {
  let line =
    [
      #("downloads", count(decisions, is_download)),
      #("uploads", count(decisions, is_upload)),
      #("local deletions", count(decisions, is_delete_local)),
      #("remote trashings", count(decisions, is_delete_remote)),
      #("local moves", count(decisions, is_move_local)),
      #("remote renames", count(decisions, is_move_remote)),
      #("conflicts", count(decisions, is_conflict)),
      #("adopted", count(decisions, is_adopt)),
      #("forgotten", count(decisions, is_forget)),
    ]
    |> list.filter(fn(category) { category.1 > 0 })
    |> list.map(fn(category) { category.0 <> " " <> int.to_string(category.1) })
    |> string.join(", ")
  case line {
    "" -> None
    described -> Some(described)
  }
}

fn count(
  decisions: List(SyncDecision),
  matches: fn(SyncDecision) -> Bool,
) -> Int {
  list.count(decisions, matches)
}

fn is_download(decision: SyncDecision) -> Bool {
  case decision {
    DownloadRemote(_, _) -> True
    _ -> False
  }
}

fn is_upload(decision: SyncDecision) -> Bool {
  case decision {
    UploadLocal(_) -> True
    _ -> False
  }
}

fn is_delete_local(decision: SyncDecision) -> Bool {
  case decision {
    DeleteLocal(_) -> True
    _ -> False
  }
}

fn is_delete_remote(decision: SyncDecision) -> Bool {
  case decision {
    DeleteRemote(_) -> True
    _ -> False
  }
}

fn is_move_local(decision: SyncDecision) -> Bool {
  case decision {
    MoveLocal(_, _, _) -> True
    _ -> False
  }
}

fn is_move_remote(decision: SyncDecision) -> Bool {
  case decision {
    MoveRemote(_, _, _) -> True
    _ -> False
  }
}

fn is_conflict(decision: SyncDecision) -> Bool {
  case decision {
    Conflict(_, _, _) -> True
    _ -> False
  }
}

fn is_adopt(decision: SyncDecision) -> Bool {
  case decision {
    AdoptKnown(_, _) -> True
    _ -> False
  }
}

fn is_forget(decision: SyncDecision) -> Bool {
  case decision {
    ForgetKnown(_) -> True
    _ -> False
  }
}
