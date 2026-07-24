# Never build a commit message with `-m` containing backticks or `$(...)`

**Scope:** git (writing any commit or tag message)
**Trigger:** about to run `git commit`/`git tag` with a message that contains
backticks, `$(`, or `${` — common because good messages name code like
`reconcile` or `rebar_uri:parse`.

Pass the message via `-F <file>` (write it with the Write tool, then
`git commit -F msg.txt`), or via a single-quoted `-m` with no backticks or
`$()`. Never put a backticked span or command substitution inside a
double-quoted `-m`.

- Real incident in this project: `git commit -m "... \`rebar_uri:parse
  undef\` ..."` ran the backticked span as a shell command; the words
  vanished and a mangled message landed on public `main` ("dies with  the
  moment"). Not worth rewriting published history over — but not worth
  risking again either.
- Observable check: commit commands in the session either use `-F` or a
  single-quoted `-m`; no double-quoted `-m` contains `` ` `` or `$(`.
- The commit messages in this repo (multi-paragraph, code-naming) are written
  to a scratch file and committed with `-F` — follow that.
