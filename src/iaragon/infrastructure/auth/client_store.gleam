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
  /// No payload: the file carries the client_secret, which must not reach a
  /// log via an upstream `string.inspect`.
  Corrupted
}

/// Closes the pre-first-login window: save_tokens only tightens the config
/// dir when it writes, so until a login completes (or on a daemon that runs
/// without one) the user-created dir sits at the umask default and
/// oauth_client.json is world-readable. Called from both entry points —
/// login start and daemon boot. The dir is the real guard (0700 blocks other
/// users regardless of each file's mode); the client file's own 0600 is
/// defence in depth, skipped when the user hasn't created it yet.
pub fn protect_config_dir(dir: String) -> Result(Nil, simplifile.FileError) {
  use Nil <- result.try(simplifile.create_directory_all(dir))
  use Nil <- result.try(simplifile.set_permissions_octal(dir, 0o700))
  let client_path = dir <> "/oauth_client.json"
  case simplifile.is_file(client_path) {
    Ok(True) -> simplifile.set_permissions_octal(client_path, 0o600)
    Ok(False) | Error(_) -> Ok(Nil)
  }
}

pub fn load_client(path: String) -> Result(OauthClient, LoadError) {
  use contents <- result.try(
    simplifile.read(from: path) |> result.map_error(Unreadable),
  )
  json.parse(from: contents, using: client_decoder())
  |> result.replace_error(Corrupted)
}

/// Accepts either iaragon's own flat `{client_id, client_secret}` or, verbatim,
/// the `client_secret_*.json` Google's console hands you to download —
/// `{"installed": {…}}` for a Desktop app, `{"web": {…}}` for a web app — so
/// the user never has to hand-transcribe the two fields into a new file.
fn client_decoder() -> decode.Decoder(OauthClient) {
  let fields = {
    use client_id <- decode.field("client_id", decode.string)
    use client_secret <- decode.field("client_secret", decode.string)
    decode.success(OauthClient(client_id:, client_secret:))
  }
  decode.one_of(fields, or: [
    decode.at(["installed"], fields),
    decode.at(["web"], fields),
  ])
}
