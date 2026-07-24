# iaragon

Bidirectional Google Drive sync daemon for Linux, on the BEAM — the
"Mirror" mode of Google Drive for Desktop: continuous two-way sync, a
complete local copy under `~/GoogleDrive`, browsable from any file
manager, with sync-status emblems on GTK file managers and KDE's Dolphin.

Written in [Gleam](https://gleam.run) on Erlang/OTP: the daemon is a
supervision tree of long-lived actors (remote poller, reconciler,
transfer pool, state owner, local watcher), so a transient failure in one
of them restarts that actor alone.

## What it does

- **Two-way mirror** driven by a pure three-way reconciliation
  (local × remote × last-known-synced state) with exhaustive
  pattern-matching — unhandled combinations are compile errors, the
  defence against silent data loss.
- **Conflicts** become Dropbox-style conflicted copies
  (`name (conflicted copy YYYY-MM-DD).ext`) — both versions survive.
- **Renames** propagate as renames in both directions (no re-transfer).
- **Local deletions propagate as trash**, never permanent deletion — and
  remote deletions move the mirror copy into `.iaragon-trash/` inside the
  mirror (30-day retention, swept at daemon start), never a bare unlink.
- **Mass-deletion valve**: a round that would delete most of the synced
  files (an unmounted mirror, an empty listing) is refused and reported in
  the journal instead of executed; override with
  `IARAGON_ALLOW_MASS_DELETE=1` when a huge cleanup really is intended.
- **Google-native docs** (Docs/Sheets/Slides) are download-only, by
  policy: browser-link files (default), or real Office/ODF exports.
- **Local changes** are detected by inotify (fallback: polling) within
  seconds; a periodic round every 30 s is the backstop.
- **Status emblems**: GVfs metadata for Nautilus/Nemo/Caja, and a
  `KOverlayIconPlugin` talking to the daemon's unix status socket for
  Dolphin (see `integrations/dolphin/`).

## Requirements

- Erlang/OTP ≥ 29 (runtime requirement), Gleam ≥ 1.17
- `inotify-tools` for the inotify watcher (optional; polling fallback)
- `gcc`/`make` at build time (sqlight's NIF), `rebar3` (filespy's fs dep)

## Install

### curl (Linux)

```sh
curl -sSL https://raw.githubusercontent.com/jeffersonguerin/iaragon/main/install.sh | sh
```

By default this **downloads a prebuilt, self-contained release** and installs
a per-user daemon under `~/.local` — **no build toolchain on your machine**.
The bundle ships its own BEAM runtime, so there is no Erlang/Gleam/rebar3/gcc
to install; it feels like downloading a program, not compiling one. It
installs the `iaragon`, `iaragon-login` and `iaragon-doctor` launchers to
`~/.local/bin`, plus a systemd **user** unit at
`~/.config/systemd/user/iaragon.service`.

If no prebuilt release exists for your architecture (or the download fails),
the script transparently **falls back to building from source**. That
fallback:

- **Doesn't conflict with your toolchain**: any dependency already installed —
  by any means (apt, brew, kerl, asdf, a manual build) — is detected and
  kept. Nothing is reinstalled or duplicated; only what is missing gets
  installed.
- **Uses a consistent method**: missing dependencies come from the one package
  manager detected on your system (apt → all from apt, and so on). A direct
  binary download is used only for a dependency your manager doesn't package
  (Gleam isn't in apt/dnf/zypper), and the script says so when it happens.
- **Is transparent**: it prints a plan of what's present and what it will
  install before acting, echoes the exact command per package, and shows a
  summary at the end.
- Needs Erlang/OTP ≥ 29 at runtime; if your distro's Erlang is older, the
  script stops with instructions rather than installing something that would
  crash. The floor is the current OTP branch on purpose: older branches either
  break outright or no longer receive httpc security fixes, and this daemon
  holds a Google OAuth token. (The prebuilt release bundles a suitable OTP, so
  this only applies to the source fallback.)

Overridable by environment: `IARAGON_FROM_SOURCE=1` (skip the prebuilt release
and build from source), `IARAGON_RELEASE_BASE` (where the prebuilt tarball is
fetched from), `IARAGON_REF` (git ref, default `main`), `IARAGON_PREFIX`
(default `~/.local`), `IARAGON_PM` (force the package manager for missing
deps, e.g. `brew`), `IARAGON_REPO`, `GLEAM_VERSION`, `REBAR3_VERSION` (pin the
rebar3 download), `IARAGON_NO_SUDO=1`.

### Homebrew

Rolling release — no version tags, so the formula is HEAD-only:

```sh
brew install --HEAD jeffersonguerin/iaragon/iaragon
```

The whole toolchain (Erlang, Gleam, rebar3, and `inotify-tools` on Linux)
comes through Homebrew as formula dependencies — one consistent source, no
mixing with a system package manager. (The daemon targets Linux; the formula
builds on macOS too, but the sync daemon is meant for a Linux desktop.)

## Running

1. Create your own Google Cloud OAuth client (one-time, 10-15 minutes —
   see the walkthrough below; running `iaragon-login` with nothing
   configured prints the same steps).
2. Log in (loopback + PKCE flow, opens your browser):

   ```sh
   iaragon-login          # or, from a source checkout: gleam run -m iaragon/login
   ```

3. Start the daemon — supervised as a systemd user service, or in the
   foreground:

   ```sh
   systemctl --user enable --now iaragon.service   # supervised
   iaragon                                          # foreground
   # from a source checkout: gleam run
   ```

   To keep the daemon running after you log out:
   `loginctl enable-linger "$USER"`.

State lives in `~/.local/share/iaragon/state.db` (SQLite). The status
socket binds at `$XDG_RUNTIME_DIR/iaragon.sock` (or
`~/.local/share/iaragon/status.sock`).

### Creating the OAuth client (one-time)

Google requires every app to register its own OAuth client, and the
full-drive scope iaragon needs is "restricted": shipping a shared client
inside iaragon would require Google verification plus a yearly security
audit. So — like rclone recommends — you create a personal client once;
it is free and takes 10-15 minutes:

1. Create (or pick) a Google Cloud project:
   <https://console.cloud.google.com/projectcreate>
2. Enable the **Google Drive API** for that project:
   <https://console.cloud.google.com/apis/library/drive.googleapis.com>
3. Configure the consent screen (app name + your e-mail, user type
   **External**): <https://console.cloud.google.com/auth/branding>
4. Create the client — "Create OAuth client" (or Credentials → Create
   credentials → OAuth client ID), application type **Desktop app**:
   <https://console.cloud.google.com/auth/clients>
5. Click **Download JSON** on the client and save that file, as-is, to
   `~/.config/iaragon/oauth_client.json` — just rename the downloaded
   `client_secret_….json`. No copying fields by hand: iaragon reads Google's
   file verbatim (the `{"installed": {…}}` wrapper it downloads, or `{"web":
   {…}}`), and a plain `{"client_id": "...", "client_secret": "..."}` still
   works too.

6. **Publish the app "In production"** (Audience → Publishing status →
   Publish app): <https://console.cloud.google.com/auth/audience>
   Left in "Testing", Google expires your login every 7 days (and you
   must add yourself as a test user). Publishing shows an "unverified
   app" warning on the consent screen — expected: it is your own app,
   used only by you.

The console UI moves around; if a link 404s, search the console for
"OAuth". The steps and the JSON shape stay the same.

## Health check

`iaragon-doctor` verifies the whole setup in one shot — OAuth client,
login/refresh token (it exercises the real refresh, catching the 7-day
"Testing" expiry before the sync silently stalls), state database, daemon
liveness (via the status socket), mirror directory and watcher backend:

```
✓ oauth client  configured (~/.config/iaragon/oauth_client.json)
✓ tokens        refresh works; access token valid until 2026-07-23T13:00:00Z
✓ state         1382 files indexed; page token present
✓ daemon        answering on /run/user/1000/iaragon.sock
✓ mirror        ~/GoogleDrive exists
✓ watcher       inotifywait found (real-time events)

all checks passed
```

It is entirely passive (reads files, one line on the status socket), so it
never disturbs the running daemon, and it exits non-zero on any failure.
For an automatic daily check in the journal, enable the bundled timer:

```sh
systemctl --user enable --now iaragon-doctor.timer
journalctl --user -u iaragon-doctor    # reports land here
```

## Development

One-time setup — points git at the versioned hooks (local CI):

```sh
./scripts/setup-dev.sh
```

The `pre-commit` hook refuses any commit that is unformatted or has a red
suite, making the project rule — every commit green — mechanical.
Emergency bypass: `git commit --no-verify`.

For [Claude Code](https://claude.com/claude-code) users, the checked-in
plugin at `.claude/skills/gleam-lsp/` wires the Gleam language server
(`gleam lsp`) into the session automatically: diagnostics after every
edit, go-to-definition, hover.

Strict TDD; the suite is the specification:

```sh
gleam test
```

Layout: `src/iaragon/domain` (pure logic — no I/O, no OTP),
`src/iaragon/application` (use-case actors), `src/iaragon/infrastructure`
(Drive/FS/persistence adapters and the supervision tree). Erlang FFI is
kept thin, in `src/iaragon_*_ffi.erl`. The full decision log lives in
[`docs/`](docs/) — architecture, verified Drive API facts, the security
and development logs, performance measurements and the data-safety
valves; `CLAUDE.md` keeps the working rules and a minimal map.

## Licence

[Apache-2.0](LICENSE).
