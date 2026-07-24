# Never silence a non-exhaustive match with a wildcard in correctness code

**Scope:** gleam (reconciliation and any decision over file presence/kind)
**Trigger:** the compiler reports a non-exhaustive `case`, or you are tempted
to add a `_ ->` arm, in `reconcile` / the sync-decision path.

Handle the missing case explicitly. Never add a `_` catch-all at the level of
file presence (`#(local, remote, known)`) or `FileKind` to make the
non-exhaustiveness error go away — that error is the project's data-loss
alarm, and a wildcard converts a silent-data-loss bug into a compile that
lied.

- Why it is load-bearing here: an unhandled presence/kind combination is
  exactly how a mirror silently deletes or overwrites a user's file. The
  compiler catching it is the safety net; a `_` disables the net.
- Observable check: `grep -n "_ ->" src/iaragon/domain/reconcile.gleam`
  returns nothing at the presence/kind level; every combination is named.
- Correct move: add the real arm and, if its behavior is non-obvious, a test
  in `test/iaragon/domain/reconcile_test.gleam` first (see
  `tdd-red-before-green.md`).
