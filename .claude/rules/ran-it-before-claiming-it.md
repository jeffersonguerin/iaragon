# Never claim a check passed without running it this session

**Scope:** project
**Trigger:** about to tell the user something "works", "passes", "is green",
"builds", "is fixed", or "is done".

State that a check passed only after actually running it in the current
session and seeing the result. If you did not run it, say what you did NOT
verify instead of implying success.

- The failure mode: reporting "tests green / it works" from expectation
  rather than from a run — the single fastest way to lose the user's trust.
- The suite runs with the project toolchain on PATH and a UTF-8 locale:
  `export PATH=/opt/otp29/bin:$PATH; export LANG=C.UTF-8; gleam test`
  (a POSIX/latin1 locale fails the accented-path tests — a locale issue, not
  a real failure, but still not "green"). Erlang FFI and the Rust tray build
  need their toolchains too (`cargo test` in `integrations/tray/`).
- Observable check: the claim is backed by command output produced this
  session. "Should pass" / "I believe it's green" is not a pass.
- Corollary: code that cannot be exercised in this environment (a live
  daemon, a session D-Bus, the real Drive API) is reported as
  "unverified here", never as "working" — see
  `test-the-seams-you-cannot-run.md`.
