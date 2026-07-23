import iaragon/domain/decision.{DeleteLocal, DeleteRemote, Noop, UploadLocal}
import iaragon/domain/safety.{DeletionsAllowed, DeletionsSuppressed}

// The mass-deletion valve: a round that wants to delete most of what was
// ever synced is almost never intent — it is an empty/corrupt listing, an
// unmounted mirror, or a bug upstream. rclone bisync aborts at >50% deletes
// for the same reason. Small mirrors and small batches always pass (an
// absolute floor), and moves/conflicts/uploads are never counted.

pub fn a_few_deletions_pass_test() {
  assert safety.judge_mass_deletion(
      [DeleteLocal("a"), DeleteRemote("id-b"), UploadLocal("c")],
      known_count: 100,
    )
    == DeletionsAllowed
}

pub fn small_mirrors_never_trip_the_valve_test() {
  // Deleting 5 of 6 synced files is a perfectly normal cleanup on a small
  // mirror — the absolute floor keeps the valve out of the way.
  assert safety.judge_mass_deletion(
      [
        DeleteLocal("a"),
        DeleteLocal("b"),
        DeleteLocal("c"),
        DeleteRemote("d"),
        DeleteRemote("e"),
      ],
      known_count: 6,
    )
    == DeletionsAllowed
}

pub fn exactly_half_still_passes_test() {
  let deletions = [
    DeleteLocal("a"),
    DeleteLocal("b"),
    DeleteLocal("c"),
    DeleteLocal("d"),
    DeleteLocal("e"),
    DeleteRemote("f"),
    DeleteRemote("g"),
    DeleteRemote("h"),
    DeleteRemote("i"),
    DeleteRemote("j"),
  ]
  assert safety.judge_mass_deletion(deletions, known_count: 20)
    == DeletionsAllowed
}

pub fn wiping_most_of_a_real_mirror_is_suppressed_test() {
  // 12 deletions over 20 knowns: above the absolute floor AND above half.
  let deletions = [
    DeleteLocal("a"),
    DeleteLocal("b"),
    DeleteLocal("c"),
    DeleteLocal("d"),
    DeleteLocal("e"),
    DeleteLocal("f"),
    DeleteRemote("g"),
    DeleteRemote("h"),
    DeleteRemote("i"),
    DeleteRemote("j"),
    DeleteRemote("k"),
    DeleteRemote("l"),
  ]
  assert safety.judge_mass_deletion(deletions, known_count: 20)
    == DeletionsSuppressed(planned: 12, known: 20)
}

pub fn non_destructive_decisions_are_not_counted_test() {
  // A huge round of downloads/uploads/noops is never suppressed.
  assert safety.judge_mass_deletion(
      [UploadLocal("a"), Noop, Noop, Noop],
      known_count: 2,
    )
    == DeletionsAllowed
}
