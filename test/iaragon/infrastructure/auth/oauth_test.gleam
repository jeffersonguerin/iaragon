import gleam/list
import gleam/string
import gleam/uri
import iaragon/infrastructure/auth/oauth.{OauthClient}

fn a_client() -> oauth.OauthClient {
  OauthClient(client_id: "abc.apps.googleusercontent.com", client_secret: "s3cr3t")
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

  assert string.starts_with(url, "https://accounts.google.com/o/oauth2/v2/auth?")

  let pairs = parse_query_of(url)
  assert list.key_find(pairs, "client_id") == Ok("abc.apps.googleusercontent.com")
  assert list.key_find(pairs, "redirect_uri") == Ok("http://127.0.0.1:8123")
  assert list.key_find(pairs, "response_type") == Ok("code")
  assert list.key_find(pairs, "scope")
    == Ok("https://www.googleapis.com/auth/drive")
  assert list.key_find(pairs, "code_challenge") == Ok("chal-lenge_123")
  assert list.key_find(pairs, "code_challenge_method") == Ok("S256")
  assert list.key_find(pairs, "state") == Ok("anti-csrf-42")
}
