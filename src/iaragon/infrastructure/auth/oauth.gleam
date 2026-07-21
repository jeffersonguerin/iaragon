//// Google OAuth 2.0 for a desktop app: authorization-code flow with PKCE and
//// a loopback redirect (OOB was removed). Endpoints verified against the
//// official docs: authorization at accounts.google.com/o/oauth2/v2/auth,
//// token at oauth2.googleapis.com/token. The client_secret of an installed
//// app is non-confidential by design.
////
//// Full-mirror sync requires the restricted `auth/drive` scope; for a
//// personal app the practical consequence is only the consent-screen
//// warning (plus 7-day refresh-token expiry while in "Testing" status).

import gleam/int
import gleam/uri

pub type OauthClient {
  OauthClient(client_id: String, client_secret: String)
}

const authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"

const drive_scope = "https://www.googleapis.com/auth/drive"

pub fn build_authorization_url(
  client: OauthClient,
  redirect_port redirect_port: Int,
  challenge challenge: String,
  state state: String,
) -> String {
  let query =
    uri.query_to_string([
      #("client_id", client.client_id),
      #("redirect_uri", build_redirect_uri(redirect_port)),
      #("response_type", "code"),
      #("scope", drive_scope),
      #("code_challenge", challenge),
      #("code_challenge_method", "S256"),
      #("state", state),
    ])
  authorization_endpoint <> "?" <> query
}

fn build_redirect_uri(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}
