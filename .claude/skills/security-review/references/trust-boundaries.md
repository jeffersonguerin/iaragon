# iaragon trust boundaries, assets and named controls

Navigation aid for the review, not a source of truth. Code drifts — **verify
each control against the current code before trusting this map; do not answer
from memory.** Each row names the file to open and a grep to confirm the control
is still there. Confidence tags: `verified` (checked this pass) age out — treat
any tag older than the last relevant change as `verify`.

## Protected assets

| | Asset | Impact if lost |
|---|---|---|
| A1 | refresh_token / access_token / client_secret | Full Drive access |
| A2 | User file content (both directions) | Data loss / exfiltration |
| A3 | Drive tree metadata (state.db, status socket) | Private structure disclosed |
| A4 | Mirror integrity | Silent corruption / loss |

## Boundaries × threats × control

### TB1 — Google Drive API → daemon
Remote data is attacker-influenceable (a file shared into the Drive controls its
name, mime, size; the server controls redirect `Location`, JSON, page tokens),
and the download/upload HTTP carries the OAuth bearer.

| STRIDE | Threat | Named control | Where |
|---|---|---|---|
| Tampering/EoP | remote name → path traversal / bad segment | `sanitize_segment` (`/`→`_`, `""`/`.`/`..` neutralised, byte scan rejects <0x20, 0x2f, 0x7f) | `domain/paths.gleam` |
| EoP | remote name → `.desktop` key injection (RCE on click) | `link_file.escape_value` (`\` first, then `\n \r \t`) | `domain/link_file.gleam` |
| Info disclosure | download redirect forwards the bearer cross-origin | FFI follows redirects with `autoredirect=false`, strips `Authorization` on scheme/host/port change, fail-closed on unparseable | `iaragon_download_ffi.erl` |
| Info disclosure/SSRF | upload `Location` points at attacker host | `validate_session_uri` — https on googleapis.com only | `drive/upload.gleam` |
| DoS | bad page token loop / unbounded pagination | 400/410 → re-seed (never blind retry); `max_pages` cap | `drive/changes.gleam`, `drive/listing.gleam` |
| Tampering | mass-delete from empty/corrupt listing | `safety.judge_mass_deletion` (≥10 AND >50% knowns → suppress) + env override | `domain/safety.gleam`, `application/reconciler.gleam` |

### TB2 — Local filesystem (mirror) → daemon
| STRIDE | Threat | Named control | Where |
|---|---|---|---|
| Info disclosure | symlink exfiltrates a file from outside the mirror | scan uses `link_info` (lstat), skips `Symlink`/`Other` | `fs/local_scan.gleam` |
| Tampering | edit-vs-transfer clobber | size+mtime recheck before destructive delete/download; deleted blob → `.iaragon-trash/` (never bare unlink) | `drive/transfer_pool.gleam`, `fs/local_trash.gleam` |
| DoS | deep folder nesting → stack overflow | `paths.walk` is a tail-recursive worklist, depth-independent | `domain/paths.gleam` |

### TB3 — OAuth (loopback redirect + browser + token endpoint)
| STRIDE | Threat | Named control | Where |
|---|---|---|---|
| Spoofing | local process steals the redirect | loopback 127.0.0.1 one-shot, `state` CSRF checked, PKCE S256 (verifier never leaves the process) | `auth/loopback.gleam`, `auth/pkce.gleam`, `auth/oauth.gleam` |
| DoS | oversized request line grows the buffer | `packet_size, 8192` on the loopback listener | `iaragon_loopback_ffi.erl` |
| Info disclosure | secret leaks into a log / error | payload-free OAuth errors + `Corrupted` variants; secret only in HTTPS POST body (never query); `string.inspect` escapes control chars. Erlang crash reports show arity not args, and the token is transient per-operation (never in actor state/message) | `auth/oauth.gleam`, `auth/token_store.gleam`, `auth/client_store.gleam` |

### TB4 — Status socket (other local processes)
| STRIDE | Threat | Named control | Where |
|---|---|---|---|
| Info disclosure | another UID reads the Drive tree | socket `8#600` + data dir `0700` | `iaragon_status_ffi.erl`, `iaragon.gleam` |
| DoS | connection flood kills the acceptor | `packet_size, 4096`; acceptor tolerates aborted handoffs (`controlling_process` guarded) | `iaragon_status_ffi.erl` |

### TB5 — Secrets / state at rest (other local users)
| STRIDE | Threat | Named control | Where |
|---|---|---|---|
| Info disclosure | another UID reads token / client / db | `token_store` 0600 via temp+rename; `protect_config_dir` dir 0700 + client 0600 at both entry points; `state.db` 0600 + data dir 0700 | `auth/token_store.gleam`, `auth/client_store.gleam`, `persistence/state_db.gleam`, `iaragon.gleam` |

Accepted threat-model limit (documented, not a gap): a malicious process running
as the **same UID** reads 0600 by definition — same model as gcloud/gh/rclone/
Drive for Desktop.

### TB6 — Installer / supply chain (`install.sh`)
| STRIDE | Threat | Named control | Where |
|---|---|---|---|
| Tampering | PREFIX injection into generated heredocs | charset guard `[A-Za-z0-9._/-]`, rejects `/` and non-absolute | `install.sh` |
| Tampering | incompatible toolchain | `otp_ok` (≥29), `gleam_new_enough` (≥1.17), `rebar3_new_enough` (≥3.27) | `install.sh` |
| EoP | truncated `curl | sh` runs a partial script | all work in `main()`, invoked on the last line | `install.sh` |

Accepted limit (documented): the Gleam binary and rebar3 escript come over TLS
with **no pinned checksum** — escape hatch is installing them yourself first.
Candidate hardening: pin sha256 per version.

### TB7 — Auto-loading agent config (public repo)
The repo ships `CLAUDE.md` and `.claude/skills/*/.lsp.json` that load into any
contributor's Claude Code session (trust gate). The `.lsp.json` `command` field
is a binary launched in their environment.

| STRIDE | Threat | Named control | Where |
|---|---|---|---|
| Tampering/EoP | a merged PR poisons a `command` or injects directives into `CLAUDE.md` | PR review must treat `.claude/**` and `CLAUDE.md` as security-sensitive; today all `command`s are benign PATH binaries (`gleam`, `elp`, `clangd`, `bash-language-server`) | `.claude/skills/*/.lsp.json`, `CLAUDE.md` |

## Out of scope (state explicitly, do not manufacture findings)
- **Agentic runtime surface** — the daemon has no LLM, no agent loop, no RAG,
  no MCP server, no persistent agent memory. The prompt-injection / tool-abuse /
  autonomy / memory-poisoning steps do not apply. The only agent-adjacent
  surface is TB7 (dev-time config in a public repo), not a runtime one.
- **Dependency CVE triage** — a separate concern; all deps track latest stable
  (see `docs/security-log.md` and the dependency audit).
