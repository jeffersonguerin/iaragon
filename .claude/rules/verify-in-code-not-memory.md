# Confirm a control exists by reading the current code, not from memory

**Scope:** project (reviews, security claims, "is X handled?" questions)
**Trigger:** about to assert that some behavior, guard, or control is present
(or absent) in the codebase.

Open the current code (grep/read) and point to the file and line before
asserting a control exists or a case is handled. A call existing is not a
call working — check ordering, early returns, and whether the guard is on the
path in question.

- The lesson, paid for repeatedly: the real defects hid exactly where a
  claim was answered from memory or from what the code "should" do. Deep
  reviews only found them by reading the path end to end.
- Observable check: each such claim carries a `file:line` (or a quoted line),
  or is explicitly labelled as unverified.
- When a control cannot be confirmed by reading (path not exercised, file not
  read), label it unverified — never upgrade an assumption to a confirmed
  fact. See `separate-fact-from-speculation.md`.
