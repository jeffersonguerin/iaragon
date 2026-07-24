# User content is moved to the local trash, never unlinked; recheck before destroy

**Scope:** gleam (any code path that deletes or overwrites a mirror file)
**Trigger:** about to `delete`, `rename`-over, or overwrite a file that holds
user content (a synced blob), or dispatching a decision that will.

Route a user blob's removal through `.iaragon-trash/` (move, never bare
unlink), and re-verify the file still matches the last-synced size+mtime
immediately before any destructive step. A generated artifact (native link,
shortcut `.desktop`, empty dir) may be deleted directly; user bytes never.

- This is the product's whole reason to exist over a network mount: losing
  Drive access must not lose the local copy, and a wrong remote deletion must
  stay recoverable. A direct `unlink` of user content is the one bug that has
  no undo.
- Observable check: destructive paths in
  `src/iaragon/infrastructure/drive/transfer_pool.gleam` go through
  `local_trash.move_to_trash` for blobs and re-check `blob_still_matches`
  (or equivalent size+mtime) before acting; bulk deletions still pass the
  mass-delete valve (`domain/safety`).
- Related invariant: remote identity is `fileId`, never a path; every local
  write destination passes through `sanitize_segment`.
