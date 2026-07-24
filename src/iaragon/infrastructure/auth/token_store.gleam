//// Persists OAuth tokens as JSON on disk (default: under ~/.config/iaragon).
//// The path is always injected, so tests never touch the real config dir.
//// Tokens are secrets: the parent dir is 0700, the file is written 0600 via
//// a temp-then-rename (atomic, never momentarily world-readable), and a
//// corrupted file's contents are NEVER carried in the error value — an
//// upstream `string.inspect` would otherwise print live tokens.

import filepath
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/result
import simplifile

pub type StoredTokens {
  StoredTokens(
    access_token: String,
    refresh_token: String,
    expires_at_unix: Int,
  )
}

pub type LoadError {
  Unreadable(cause: simplifile.FileError)
  /// No payload on purpose: the file contents are token material and must
  /// never be carried where an upstream `string.inspect` could print them.
  Corrupted
}

pub fn save_tokens(
  path: String,
  tokens: StoredTokens,
) -> Result(Nil, simplifile.FileError) {
  use Nil <- result.try(create_parent_directory(path))
  let contents =
    json.object([
      #("access_token", json.string(tokens.access_token)),
      #("refresh_token", json.string(tokens.refresh_token)),
      #("expires_at_unix", json.int(tokens.expires_at_unix)),
    ])
    |> json.to_string
  // Temp-then-rename: the real path only ever appears atomically, already
  // 0600 — no window where a reader sees a half-written or world-readable
  // token file (and the 0700 parent dir blocks other users regardless).
  // The temp name is UNIQUE per write: refreshes can race (poller, pool and
  // doctor each refresh on demand), and with a fixed name one writer could
  // rename the other's half-written temp into place, corrupting tokens.json
  // until a manual re-login.
  let temp = path <> ".tmp." <> int.to_string(int.random(1_000_000_000))
  use Nil <- result.try(simplifile.write(to: temp, contents: contents))
  use Nil <- result.try(simplifile.set_permissions_octal(temp, 0o600))
  simplifile.rename(at: temp, to: path)
}

pub fn load_tokens(path: String) -> Result(StoredTokens, LoadError) {
  use contents <- result.try(
    simplifile.read(from: path) |> result.map_error(Unreadable),
  )
  let decoder = {
    use access_token <- decode.field("access_token", decode.string)
    use refresh_token <- decode.field("refresh_token", decode.string)
    use expires_at_unix <- decode.field("expires_at_unix", decode.int)
    decode.success(StoredTokens(access_token:, refresh_token:, expires_at_unix:))
  }
  json.parse(from: contents, using: decoder)
  |> result.replace_error(Corrupted)
}

fn create_parent_directory(path: String) -> Result(Nil, simplifile.FileError) {
  let dir = filepath.directory_name(path)
  use Nil <- result.try(simplifile.create_directory_all(dir))
  // A secrets directory: owner-only, so the token-file window is moot.
  simplifile.set_permissions_octal(dir, 0o700)
}
