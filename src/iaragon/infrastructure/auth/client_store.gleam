//// Loads the OAuth client (client_id + client_secret) from JSON on disk.
//// The user creates this file once, from their Google Cloud project's
//// "Desktop app" credentials. An installed app's client_secret is
//// non-confidential by design, but the file still lives in the config dir.

import gleam/dynamic/decode
import gleam/json
import gleam/result
import iaragon/infrastructure/auth/oauth.{type OauthClient, OauthClient}
import simplifile

pub type LoadError {
  Unreadable(cause: simplifile.FileError)
  Corrupted(contents: String)
}

pub fn load_client(path: String) -> Result(OauthClient, LoadError) {
  use contents <- result.try(
    simplifile.read(from: path) |> result.map_error(Unreadable),
  )
  let decoder = {
    use client_id <- decode.field("client_id", decode.string)
    use client_secret <- decode.field("client_secret", decode.string)
    decode.success(OauthClient(client_id:, client_secret:))
  }
  json.parse(from: contents, using: decoder)
  |> result.replace_error(Corrupted(contents))
}
