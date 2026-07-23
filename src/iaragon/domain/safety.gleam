//// The mass-deletion valve. A single sync round that wants to delete most
//// of everything ever synced is almost never user intent: it is an
//// unmounted mirror (the scan sees an empty directory), an empty/corrupt
//// remote listing, or a bug upstream — and letting it through would wipe
//// one side. Mature tools ship the same valve (rclone bisync aborts a run
//// that would delete more than half a side, Syncthing stops on a missing
//// folder marker); this is the pure decision for ours.
////
//// Policy: a round's DeleteLocal + DeleteRemote decisions are suppressed
//// when they are BOTH at least `minimum_deletions` (small batches always
//// pass) AND more than half of the known synced files (big legitimate
//// cleanups on small mirrors always pass). Moves, conflicts, uploads,
//// downloads and index bookkeeping are never counted — only the two
//// destructive shapes.

import gleam/list
import iaragon/domain/decision.{type SyncDecision, DeleteLocal, DeleteRemote}

pub type DeletionVerdict {
  DeletionsAllowed
  /// The round is refused its deletions: `planned` of `known` synced files
  /// would be destroyed. The caller keeps every non-destructive decision,
  /// reports loudly, and lets the next round re-decide.
  DeletionsSuppressed(planned: Int, known: Int)
}

/// Below this many deletions the valve never trips.
const minimum_deletions = 10

pub fn judge_mass_deletion(
  decisions: List(SyncDecision),
  known_count known_count: Int,
) -> DeletionVerdict {
  let planned = list.count(decisions, is_deletion)
  case planned >= minimum_deletions && planned * 2 > known_count {
    True -> DeletionsSuppressed(planned: planned, known: known_count)
    False -> DeletionsAllowed
  }
}

/// Strip only the destructive decisions, keeping everything else flowing.
pub fn drop_deletions(decisions: List(SyncDecision)) -> List(SyncDecision) {
  list.filter(decisions, fn(decision) { !is_deletion(decision) })
}

fn is_deletion(decision: SyncDecision) -> Bool {
  case decision {
    DeleteLocal(_) | DeleteRemote(_) -> True
    _ -> False
  }
}
