//// Persists OAuth tokens as JSON on disk (default: under ~/.config/iaragon).
//// The path is always injected, so tests never touch the real config dir.
//// Tokens are secrets: the file is chmod 600 after every save.

import filepath
import gleam/dynamic/decode
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
  Corrupted(contents: String)
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
  use Nil <- result.try(simplifile.write(to: path, contents: contents))
  simplifile.set_permissions_octal(path, 0o600)
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
  |> result.replace_error(Corrupted(contents))
}

fn create_parent_directory(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.create_directory_all(filepath.directory_name(path))
}
