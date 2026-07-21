import gleam/http/response
import iaragon/infrastructure/auth/oauth.{OauthClient}
import iaragon/infrastructure/auth/token_manager.{TokenSource}
import iaragon/infrastructure/auth/token_store.{type StoredTokens, StoredTokens}

// The manager hands out a valid access token, refreshing (and persisting)
// behind the scenes when the stored one is about to expire. Clock and HTTP
// are injected; each test gets its own tokens file under the build dir.

const scratch_dir = "build/test-scratch/token_manager"

const now = 1_800_000_000

fn a_source(
  name: String,
  send: oauth.SendRequest,
  stored: StoredTokens,
) -> token_manager.TokenSource {
  let path = scratch_dir <> "/" <> name <> "/tokens.json"
  let assert Ok(Nil) = token_store.save_tokens(path, stored)
  TokenSource(
    send: send,
    client: OauthClient(client_id: "abc", client_secret: "s3cr3t"),
    tokens_path: path,
    clock: fn() { now },
  )
}

fn a_forbidden_send() -> oauth.SendRequest {
  fn(_request) { panic as "no HTTP call was expected in this test" }
}

const a_refresh_payload = "{\"access_token\":\"at-new\",\"expires_in\":3600,"
  <> "\"token_type\":\"Bearer\"}"

pub fn a_fresh_stored_token_is_returned_without_http_test() {
  let stored =
    StoredTokens(
      access_token: "at-fresh",
      refresh_token: "rt-1",
      expires_at_unix: now + 3000,
    )
  let source = a_source("fresh", a_forbidden_send(), stored)
  assert token_manager.obtain_access_token(source) == Ok("at-fresh")
}

pub fn an_expiring_token_is_refreshed_and_persisted_test() {
  let stored =
    StoredTokens(
      access_token: "at-old",
      refresh_token: "rt-1",
      expires_at_unix: now + 30,
    )
  let send = fn(_request) {
    Ok(response.Response(status: 200, headers: [], body: a_refresh_payload))
  }
  let source = a_source("expiring", send, stored)

  assert token_manager.obtain_access_token(source) == Ok("at-new")

  // The refreshed access token is persisted, and the refresh token is kept
  // when Google's response omits it (the usual case).
  assert token_store.load_tokens(source.tokens_path)
    == Ok(StoredTokens(
      access_token: "at-new",
      refresh_token: "rt-1",
      expires_at_unix: now + 3600,
    ))
}

pub fn a_rotated_refresh_token_replaces_the_stored_one_test() {
  let stored =
    StoredTokens(
      access_token: "at-old",
      refresh_token: "rt-old",
      expires_at_unix: now - 10,
    )
  let rotated_payload =
    "{\"access_token\":\"at-new\",\"expires_in\":3600,"
    <> "\"refresh_token\":\"rt-new\",\"token_type\":\"Bearer\"}"
  let send = fn(_request) {
    Ok(response.Response(status: 200, headers: [], body: rotated_payload))
  }
  let source = a_source("rotated", send, stored)

  let assert Ok("at-new") = token_manager.obtain_access_token(source)
  let assert Ok(StoredTokens(refresh_token: "rt-new", ..)) =
    token_store.load_tokens(source.tokens_path)
}

pub fn a_missing_tokens_file_asks_for_login_test() {
  let source =
    TokenSource(
      send: a_forbidden_send(),
      client: OauthClient(client_id: "abc", client_secret: "s3cr3t"),
      tokens_path: scratch_dir <> "/absent/tokens.json",
      clock: fn() { now },
    )
  let assert Error(token_manager.MissingLogin(_)) =
    token_manager.obtain_access_token(source)
}

pub fn a_refused_refresh_is_reported_and_keeps_the_old_file_test() {
  let stored =
    StoredTokens(
      access_token: "at-old",
      refresh_token: "rt-dead",
      expires_at_unix: now - 10,
    )
  let send = fn(_request) {
    Ok(response.Response(
      status: 400,
      headers: [],
      body: "{\"error\":\"invalid_grant\"}",
    ))
  }
  let source = a_source("refused", send, stored)

  let assert Error(token_manager.RefreshFailed(_)) =
    token_manager.obtain_access_token(source)
  assert token_store.load_tokens(source.tokens_path) == Ok(stored)
}

pub fn expiry_uses_a_safety_margin_test() {
  // 45 seconds left is inside the 60-second margin: refresh, don't risk it.
  let stored =
    StoredTokens(
      access_token: "at-old",
      refresh_token: "rt-1",
      expires_at_unix: now + 45,
    )
  let send = fn(_request) {
    Ok(response.Response(status: 200, headers: [], body: a_refresh_payload))
  }
  let source = a_source("margin", send, stored)
  assert token_manager.obtain_access_token(source) == Ok("at-new")
}
