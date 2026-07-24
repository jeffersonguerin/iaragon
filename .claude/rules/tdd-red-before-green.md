# Production code is born from a failing test

**Scope:** gleam (production code under `src/`)
**Trigger:** about to add or change behavior in a `src/**/*.gleam` module.

Write the failing test FIRST and observe it red, then write the minimum
production code to make it green, then refactor with the suite green. Never
write production code ahead of a test that exercises it.

- The recurring failure elsewhere: jumping straight to the implementation and
  adding tests after (or not at all), so the test never actually proved the
  behavior was absent before the change.
- A compile error from a not-yet-existing type/function COUNTS as red — that
  is the expected first state, not something to avoid by stubbing first.
- Observable check: the turn shows the test failing (or the compile error)
  before the implementation edit, and green after. If you cannot show the
  red, you skipped the step.
- Example from this repo: every `*_test.gleam` case was added before its
  `src/` counterpart; e.g. `test/iaragon/domain/reconcile_test.gleam` pins a
  decision, then `src/iaragon/domain/reconcile.gleam` satisfies it.

Exception: pure refactors that change no behavior (the existing suite is the
test) and non-code files (docs, packaging) are out of scope.
