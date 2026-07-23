# Contributing to iaragon

Thanks for your interest! iaragon is a small, opinionated project with a
few non-negotiable disciplines — they are what keep a data-destroying bug
out of a sync daemon. Read this once and everything else follows.

## Dev setup

- **Erlang/OTP ≥ 26** (older OTP compiles but crashes at runtime) and
  **Gleam ≥ 1.17**; `rebar3` on PATH; `gcc`/`make` (sqlight's NIF);
  `inotify-tools` optional (tests fall back to polling without it).
- One-time, from the repo root:

  ```sh
  ./scripts/setup-dev.sh
  ```

  This points git at the versioned hooks — the project's local CI:
  - `pre-commit`: refuses unformatted code (`gleam format --check`) and a
    red suite (`gleam test`). **Every commit is green**, mechanically.
  - `pre-push`: refuses compiler warnings
    (`gleam build --warnings-as-errors`). In Gleam the compiler is the
    linter; nothing leaves with warnings.

## How changes are made

- **Strict TDD** — red → green → refactor. Every line of production code
  is born from a failing test (a compile error for a not-yet-existing
  type/function counts as red). Look at any module in `test/` mirroring
  `src/` for the house style.
- **Layers (DDD)** — `domain/` is pure (zero I/O, zero OTP, stdlib only),
  `application/` orchestrates use cases, `infrastructure/` adapts to the
  world (FS, Drive API, SQLite, supervision). The dependency rule: domain
  imports nothing from the other layers; application never imports
  concrete infrastructure — it receives typed `Subject`s and records of
  functions at initialisation. Reviews enforce this by import inspection.
- **Naming is verb-first at every call boundary** — types are nouns
  (`SyncDecision`, `RemoteFile`); operations and messages are verbs of
  intent (`reconcile`, `PutKnown`, `EnqueueUpload`). One documented
  exception: `pub fn supervised()` on actor modules (the canonical
  gleam_otp pattern).
- **Erlang FFI stays thin** and only where indispensable — see the four
  existing `src/iaragon_*_ffi.erl` files for the size budget.

## Invariants that must never break

They are listed in [CLAUDE.md](CLAUDE.md) and detailed in
[docs/](docs/) — the short version:

- `reconcile` is pure and its presence-matching is exhaustive with no `_`
  catch-all: an unhandled combination must be a compile error.
- Transfer settles update the in-memory remote model immediately.
- Deletions go through the mass-deletion valve, and a local blob is moved
  to `.iaragon-trash/` — user content is never unlinked directly.
- Remote identity is `fileId`, never path; every local write destination
  goes through `sanitize_segment`.
- Google-native files never become `UploadLocal`.

## Drive API facts

**Never invent API behavior.** Everything this project relies on is
verified against the official docs and recorded in
[docs/drive-api.md](docs/drive-api.md) with dates. If your change depends
on an API fact that is not there, verify it in the official documentation
first and add it — uncertainty is stated, not papered over.

## Running things

```sh
gleam test        # the suite is the specification (~300 tests)
gleam build --warnings-as-errors
gleam run         # daemon in the foreground
gleam run -m iaragon/login    # interactive OAuth login
gleam run -m iaragon/doctor   # health check
```

The perf/scale tests print their measurements on every run; their asserts
are property canaries (streaming stays streaming, steady state stays
zero-work), not brittle micro-timings.

## Releases and history

Rolling release: no version tags, no changelog. `main` is always green
and installable. The project log lives in [docs/](docs/), split by type —
when your change touches an area, update the matching file
(development log, security log, API facts, performance, data safety).

## Pull requests

Small and focused beats large and mixed. A good PR arrives with its tests
(written first), a green suite, zero warnings, and a message that says
*why* — the diff already says *what*.

## Security

Please do not open public issues for suspected vulnerabilities — use
GitHub's private vulnerability reporting on this repository (Security →
Report a vulnerability). The threat model and past reviews are in
[docs/security-log.md](docs/security-log.md).
