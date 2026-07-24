# One concern per commit, and never commit over a red suite

**Scope:** git
**Trigger:** about to stage and commit.

Keep each commit to a single coherent change with its tests, and let the
commit land only with the suite green. Do not batch unrelated fixes into one
commit, and do not bypass the hooks to commit red.

- The green-per-commit guarantee is enforced mechanically by `.githooks/`
  (`pre-commit` = format + `gleam test`); this rule is the behavioral half:
  do not reach for `--no-verify`, and do not lump a domain fix, a packaging
  tweak and a doc edit into one commit because they happened in the same
  session. The project history is one focused commit per concern
  (see `git log` — each fix names one thing) and that is the bar.
- Observable check: a commit's diff maps to its one-line summary; the suite
  was green when it landed (the hook ran, not skipped).
- When a change touches code AND its docs/tests for the SAME concern, that is
  still one commit — coherence, not file count, is the test.
