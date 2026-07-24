# Never invent an API or library behavior — verify, or say you are unsure

**Scope:** project (Google Drive API, OTP/inets, Gleam deps, systemd, dpkg…)
**Trigger:** about to rely on how an external API, endpoint, library function,
or tool behaves.

Verify the behavior against the official documentation (or the installed
source) before depending on it; if you cannot verify it, say so plainly
rather than stating it as fact. Record newly-verified Drive-API facts, with
the date, in `docs/drive-api.md`.

- The failure mode: confidently asserting an endpoint field, a default, a
  status-code semantics, or a flag that turns out not to exist — then
  building on the fiction.
- This project has been burned by unstated assumptions that only broke at
  runtime (e.g. `{stream, path}` APPENDS; `binary_to_list` double-encodes
  non-ASCII paths; GitHub's `releases/latest` alias excludes prereleases).
  Each is now a verified, dated note — that is the bar.
- Observable check: a behavioral claim about an external system is either
  backed by a doc/source reference or hedged as unverified. "I think the API
  does X" is a prompt to go check, not to ship.
