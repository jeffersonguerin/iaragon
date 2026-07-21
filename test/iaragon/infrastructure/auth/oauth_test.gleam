import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import iaragon/infrastructure/auth/oauth.{OauthClient, TokenResponse}

fn a_client() -> oauth.OauthClient {
  OauthClient(
    client_id: "abc.apps.googleusercontent.com",
    client_secret: "s3cr3t",
  )
}

fn parse_query_of(url: String) -> List(#(String, String)) {
  let assert Ok(#(_, query)) = string.split_once(url, "?")
  let assert Ok(pairs) = uri.parse_query(query)
  pairs
}

pub fn authorization_url_points_at_google_with_pkce_test() {
  let url =
    oauth.build_authorization_url(
      a_client(),
      redirect_port: 8123,
      challenge: "chal-lenge_123",
      state: "anti-csrf-42",
    )

  assert string.starts_with(
    url,
    "https://accounts.google.com/o/oauth2/v2/auth?",
  )

  let pairs = parse_query_of(url)
  assert list.key_find(pairs, "client_id")
    == Ok("abc.apps.googleusercontent.com")
  assert list.key_find(pairs, "redirect_uri") == Ok("http://127.0.0.1:8123")
  assert list.key_find(pairs, "response_type") == Ok("code")
  assert list.key_find(pairs, "scope")
    == Ok("https://www.googleapis.com/auth/drive")
  assert list.key_find(pairs, "code_challenge") == Ok("chal-lenge_123")
  assert list.key_find(pairs, "code_challenge_method") == Ok("S256")
  assert list.key_find(pairs, "state") == Ok("anti-csrf-42")
}

// --- Token exchange / refresh ------------------------------------------------

fn respond_with(
  inbox: process.Subject(request.Request(String)),
  status: Int,
  body: String,
) -> oauth.SendRequest {
  fn(request) {
    process.send(inbox, request)
    Ok(response.Response(status: status, headers: [], body: body))
  }
}

const a_token_payload = "{\"access_token\":\"at-1\",\"expires_in\":3599,"
  <> "\"refresh_token\":\"rt-1\",\"scope\":\"https://www.googleapis.com/auth/drive\","
  <> "\"token_type\":\"Bearer\"}"

pub fn exchanging_the_code_posts_the_form_and_parses_tokens_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, a_token_payload)

  let assert Ok(tokens) =
    oauth.exchange_code(
      send,
      a_client(),
      redirect_port: 8123,
      code: "code-1",
      verifier: "verif-1",
    )
  assert tokens
    == TokenResponse(
      access_token: "at-1",
      refresh_token: Some("rt-1"),
      expires_in_seconds: 3599,
    )

  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.method == http.Post
  assert sent.host == "oauth2.googleapis.com"
  assert sent.path == "/token"
  assert request.get_header(sent, "content-type")
    == Ok("application/x-www-form-urlencoded")
  let assert Ok(form) = uri.parse_query(sent.body)
  assert list.key_find(form, "grant_type") == Ok("authorization_code")
  assert list.key_find(form, "code") == Ok("code-1")
  assert list.key_find(form, "code_verifier") == Ok("verif-1")
  assert list.key_find(form, "client_id")
    == Ok("abc.apps.googleusercontent.com")
  assert list.key_find(form, "client_secret") == Ok("s3cr3t")
  assert list.key_find(form, "redirect_uri") == Ok("http://127.0.0.1:8123")
}

pub fn refreshing_posts_the_refresh_grant_test() {
  let inbox = process.new_subject()
  let no_refresh_payload =
    "{\"access_token\":\"at-2\",\"expires_in\":3599,\"token_type\":\"Bearer\"}"
  let send = respond_with(inbox, 200, no_refresh_payload)

  let assert Ok(tokens) =
    oauth.refresh_access_token(send, a_client(), refresh_token: "rt-1")
  assert tokens
    == TokenResponse(
      access_token: "at-2",
      refresh_token: None,
      expires_in_seconds: 3599,
    )

  let assert Ok(sent) = process.receive(inbox, 100)
  let assert Ok(form) = uri.parse_query(sent.body)
  assert list.key_find(form, "grant_type") == Ok("refresh_token")
  assert list.key_find(form, "refresh_token") == Ok("rt-1")
  assert list.key_find(form, "client_id")
    == Ok("abc.apps.googleusercontent.com")
}

pub fn transport_failure_is_reported_test() {
  let send = fn(_request) { Error("econnrefused") }
  assert oauth.refresh_access_token(send, a_client(), refresh_token: "rt-1")
    == Error(oauth.TransportFailed("econnrefused"))
}

pub fn server_refusal_carries_status_and_body_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 400, "{\"error\":\"invalid_grant\"}")
  assert oauth.refresh_access_token(send, a_client(), refresh_token: "rt-1")
    == Error(oauth.RefusedByServer(400, "{\"error\":\"invalid_grant\"}"))
}

pub fn unparseable_success_body_is_reported_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, "not json")
  assert oauth.refresh_access_token(send, a_client(), refresh_token: "rt-1")
    == Error(oauth.UnexpectedPayload("not json"))
}
