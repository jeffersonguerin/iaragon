# For code you cannot exercise here, pin a runnable regression test and flag the gap

**Scope:** project (Erlang FFI, the Rust tray, packaging, anything needing a
live daemon / session D-Bus / the real Drive API / systemd)
**Trigger:** writing or changing code whose real behavior cannot be executed
in this environment.

Extract the checkable logic into something the local suite CAN run and test
that; then state explicitly what remained unverified-in-environment and what
would exercise it for real. Do not let "can't run it here" mean "didn't test
it".

- The pattern, confirmed twice: the session's worst defects clustered exactly
  in the seams that unit tests don't cross — the tray's socket read
  (`read_to_string` vs one line), path double-encoding in the status FFIs,
  materialisation-vs-disambiguation ordering, GitHub's release-alias
  semantics. Each was found late precisely because that seam was never
  exercised.
- What "runnable regression test" looks like here: a mock unix-socket server
  in a Rust `#[test]`; an accented socket path pinned on disk in a gleeunit
  test against the real FFI; parsing/summarising logic split out from the
  I/O. Prefer those over "looks right".
- Observable check: the change ships with a test that runs in `gleam test`
  or `cargo test`, AND the reply names the residual manual check (e.g. "run
  in WSL: the tray icon; a real OAuth redirect"). See
  `ran-it-before-claiming-it.md`.
