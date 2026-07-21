//// Google OAuth 2.0 for a desktop app: authorization-code flow with PKCE and
//// a loopback redirect (OOB was removed). Endpoints verified against the
//// official docs: authorization at accounts.google.com/o/oauth2/v2/auth,
//// token at oauth2.googleapis.com/token. The client_secret of an installed
//// app is non-confidential by design.
////
//// Full-mirror sync requires the restricted `auth/drive` scope; for a
//// personal app the practical consequence is only the consent-screen
//// warning (plus 7-day refresh-token expiry while in "Testing" status).

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{type Option, None}
import gleam/result
import gleam/uri

pub type OauthClient {
  OauthClient(client_id: String, client_secret: String)
}

pub type TokenResponse {
  TokenResponse(
    access_token: String,
    refresh_token: Option(String),
    expires_in_seconds: Int,
  )
}

pub type OauthError {
  TransportFailed(reason: String)
  RefusedByServer(status: Int, body: String)
  UnexpectedPayload(body: String)
}

/// The HTTP transport, injected so tests never touch the network.
pub type SendRequest =
  fn(Request(String)) -> Result(Response(String), String)

const authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"

const token_host = "oauth2.googleapis.com"

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

pub fn exchange_code(
  send: SendRequest,
  client: OauthClient,
  redirect_port redirect_port: Int,
  code code: String,
  verifier verifier: String,
) -> Result(TokenResponse, OauthError) {
  request_tokens(send, [
    #("grant_type", "authorization_code"),
    #("code", code),
    #("code_verifier", verifier),
    #("client_id", client.client_id),
    #("client_secret", client.client_secret),
    #("redirect_uri", build_redirect_uri(redirect_port)),
  ])
}

pub fn refresh_access_token(
  send: SendRequest,
  client: OauthClient,
  refresh_token refresh_token: String,
) -> Result(TokenResponse, OauthError) {
  request_tokens(send, [
    #("grant_type", "refresh_token"),
    #("refresh_token", refresh_token),
    #("client_id", client.client_id),
    #("client_secret", client.client_secret),
  ])
}

fn request_tokens(
  send: SendRequest,
  form: List(#(String, String)),
) -> Result(TokenResponse, OauthError) {
  let request =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_scheme(http.Https)
    |> request.set_host(token_host)
    |> request.set_path("/token")
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(uri.query_to_string(form))

  use response <- result.try(send(request) |> result.map_error(TransportFailed))
  case response.status {
    200 -> parse_token_payload(response.body)
    status -> Error(RefusedByServer(status, response.body))
  }
}

fn parse_token_payload(body: String) -> Result(TokenResponse, OauthError) {
  let decoder = {
    use access_token <- decode.field("access_token", decode.string)
    use refresh_token <- decode.optional_field(
      "refresh_token",
      None,
      decode.optional(decode.string),
    )
    use expires_in_seconds <- decode.field("expires_in", decode.int)
    decode.success(TokenResponse(
      access_token:,
      refresh_token:,
      expires_in_seconds:,
    ))
  }
  json.parse(from: body, using: decoder)
  |> result.replace_error(UnexpectedPayload(body))
}
