# Get explicit per-action approval before anything irreversible or outward-facing

**Scope:** git + project (published history, remote visibility, external
publish, pushes outside the designated branch)
**Trigger:** about to rewrite/force-push published history, change repository
visibility, publish a release or package to an external host, post to
GitHub (PR/issue/comment), or push to any branch other than the designated
feature branch / its ff-merge to `main`.

Stop and get the user's explicit approval for THAT action first. Approval for
one such action does not extend to the next; a standing rule never
authorizes it on its own.

- Why: these leave the local sandbox — a force-push, a public release, a
  visibility flip, or a comment on a public PR can't be quietly undone, and
  can expose or mislead. The project's normal loop (commit on the feature
  branch, ff-merge to `main`, push both) is pre-authorized; anything beyond
  it is not.
- Observable check: for any such step, the transcript shows the user asked
  for it (or approved it) in their own words this session — not inferred
  from a general "go ahead".
- Corollary already in force: no `--no-verify` to dodge a red hook; fix the
  red instead.
