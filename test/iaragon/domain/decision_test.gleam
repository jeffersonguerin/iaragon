import gleam/option.{None, Some}
import iaragon/domain/decision.{
  AdoptKnown, Conflict, DeleteLocal, DeleteRemote, DownloadRemote, EditEdit,
  ForgetKnown, MoveLocal, MoveRemote, Noop, UploadLocal,
}

// The audit line for a reconcile round: which work the round decided, as
// counts per category, nonzero categories only. A workless round yields
// None so steady state (a round every 30 s) never spams the journal —
// the forensic value is exactly the rounds that DID something, which is
// what a silent daemon made impossible to reconstruct after the fact.

pub fn a_workless_round_has_nothing_to_describe_test() {
  assert decision.describe_workload([]) == None
  assert decision.describe_workload([Noop, Noop, Noop]) == None
}

pub fn every_category_is_counted_and_zeroes_are_omitted_test() {
  assert decision.describe_workload([
      DownloadRemote("id-1", "a"),
      DownloadRemote("id-2", "b"),
      UploadLocal("c"),
      DeleteLocal("d"),
      DeleteRemote("id-3"),
      MoveLocal("id-4", "e", "f"),
      MoveRemote("id-5", "g", "h"),
      Conflict("i", "id-6", EditEdit),
      AdoptKnown("id-7", "j"),
      ForgetKnown("id-8"),
      ForgetKnown("id-9"),
      Noop,
    ])
    == Some(
      "downloads 2, uploads 1, local deletions 1, remote trashings 1,"
      <> " local moves 1, remote renames 1, conflicts 1, adopted 1,"
      <> " forgotten 2",
    )
}

pub fn only_the_present_categories_appear_test() {
  assert decision.describe_workload([
      ForgetKnown("id-1"),
      ForgetKnown("id-2"),
      ForgetKnown("id-3"),
      Noop,
    ])
    == Some("forgotten 3")
}
