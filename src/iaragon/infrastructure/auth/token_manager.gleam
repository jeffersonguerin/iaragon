//// Hands out a valid access token for API calls, refreshing behind the
//// scenes when the stored one is inside the expiry safety margin. Clock and
//// HTTP transport are injected so the logic is fully testable. A refresh
//// response usually omits the refresh token — the stored one is kept unless
//// Google rotates it.

import gleam/option.{None, Some}
import gleam/result
import gleam/string
import iaragon/infrastructure/auth/oauth
import iaragon/infrastructure/auth/token_store.{type StoredTokens, StoredTokens}

/// Everything needed to produce tokens on demand.
pub type TokenSource {
  TokenSource(
    send: oauth.SendRequest,
    client: oauth.OauthClient,
    tokens_path: String,
    /// Unix seconds; injected for testability.
    clock: fn() -> Int,
  )
}

pub type TokenError {
  /// No (readable) stored tokens — the user must run the login command.
  MissingLogin(detail: String)
  RefreshFailed(detail: String)
}

/// Refresh this many seconds before the recorded expiry, so a token is never
/// handed out just as it dies mid-request.
const expiry_margin_seconds = 60

pub fn obtain_access_token(source: TokenSource) -> Result(String, TokenError) {
  use stored <- result.try(
    token_store.load_tokens(source.tokens_path)
    |> result.map_error(fn(error) { MissingLogin(string.inspect(error)) }),
  )
  let now = source.clock()
  case now < stored.expires_at_unix - expiry_margin_seconds {
    True -> Ok(stored.access_token)
    False -> refresh_and_persist(source, stored, now)
  }
}

fn refresh_and_persist(
  source: TokenSource,
  stored: StoredTokens,
  now: Int,
) -> Result(String, TokenError) {
  use response <- result.try(
    oauth.refresh_access_token(
      source.send,
      source.client,
      refresh_token: stored.refresh_token,
    )
    |> result.map_error(fn(error) { RefreshFailed(string.inspect(error)) }),
  )
  let refresh_token = case response.refresh_token {
    Some(rotated) -> rotated
    None -> stored.refresh_token
  }
  use Nil <- result.try(
    token_store.save_tokens(
      source.tokens_path,
      StoredTokens(
        access_token: response.access_token,
        refresh_token: refresh_token,
        expires_at_unix: now + response.expires_in_seconds,
      ),
    )
    |> result.map_error(fn(error) { RefreshFailed(string.inspect(error)) }),
  )
  Ok(response.access_token)
}
