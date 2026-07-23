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
- **Local deletions propagate as trash**, never permanent deletion.
- **Google-native docs** (Docs/Sheets/Slides) are download-only, by
  policy: browser-link files (default), or real Office/ODF exports.
- **Local changes** are detected by inotify (fallback: polling) within
  seconds; a periodic round every 30 s is the backstop.
- **Status emblems**: GVfs metadata for Nautilus/Nemo/Caja, and a
  `KOverlayIconPlugin` talking to the daemon's unix status socket for
  Dolphin (see `integrations/dolphin/`).

## Requirements

- Erlang/OTP ≥ 26 (runtime requirement), Gleam ≥ 1.17
- `inotify-tools` for the inotify watcher (optional; polling fallback)
- `gcc`/`make` at build time (sqlight's NIF), `rebar3` (filespy's fs dep)

## Running

1. Create a Google Cloud OAuth client of type **Desktop app** and save it
   as `~/.config/iaragon/oauth_client.json`:
   `{"client_id": "...", "client_secret": "..."}`
2. Log in (loopback + PKCE flow, opens your browser):

   ```sh
   gleam run -m iaragon/login
   ```

3. Start the daemon:

   ```sh
   gleam run
   ```

State lives in `~/.local/share/iaragon/state.db` (SQLite). The status
socket binds at `$XDG_RUNTIME_DIR/iaragon.sock` (or
`~/.local/share/iaragon/status.sock`).

## Development

One-time setup — points git at the versioned hooks (local CI):

```sh
./scripts/setup-dev.sh
```

The `pre-commit` hook refuses any commit that is unformatted or has a red
suite, making the project rule — every commit green — mechanical.
Emergency bypass: `git commit --no-verify`.

Strict TDD; the suite is the specification:

```sh
gleam test
```

Layout: `src/iaragon/domain` (pure logic — no I/O, no OTP),
`src/iaragon/application` (use-case actors), `src/iaragon/infrastructure`
(Drive/FS/persistence adapters and the supervision tree). Erlang FFI is
kept thin, in `src/iaragon_*_ffi.erl`. See `CLAUDE.md` for the full
decision log.

## Licence

[Apache-2.0](LICENSE).
