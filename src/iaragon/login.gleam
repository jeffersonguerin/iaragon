//// Interactive OAuth login: `gleam run -m iaragon/login`.
////
//// Thin composition of the tested pieces (client_store, pkce, loopback,
//// oauth, token_store) — this module only wires them together and talks to
//// the human, so it carries no logic of its own to unit-test.
////
//// Prerequisite: ~/.config/iaragon/oauth_client.json with the Desktop-app
//// credentials from your Google Cloud project:
////   {"client_id": "…", "client_secret": "…"}

import envoy
import gleam/float
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import iaragon/infrastructure/auth/client_store
import iaragon/infrastructure/auth/loopback
import iaragon/infrastructure/auth/oauth
import iaragon/infrastructure/auth/pkce
import iaragon/infrastructure/auth/token_store.{StoredTokens}

const redirect_timeout_ms = 300_000

pub fn main() -> Nil {
  case run_login() {
    Ok(path) -> io.println("Login successful. Tokens saved to " <> path <> ".")
    Error(message) -> io.println_error("Login failed: " <> message)
  }
}

fn run_login() -> Result(String, String) {
  use home <- result.try(
    envoy.get("HOME") |> result.replace_error("HOME is not set"),
  )
  let config_dir = home <> "/.config/iaragon"
  // Before anything else: the dir will hold the client secret and, after this
  // run, the tokens — owner-only from the start, not only after the first
  // save_tokens.
  use Nil <- result.try(
    client_store.protect_config_dir(config_dir)
    |> result.map_error(fn(cause) {
      "cannot restrict " <> config_dir <> " (" <> string.inspect(cause) <> ")"
    }),
  )
  use client <- result.try(
    client_store.load_client(config_dir <> "/oauth_client.json")
    |> result.map_error(fn(error) {
      case error {
        client_store.Unreadable(cause) ->
          "cannot read "
          <> config_dir
          <> "/oauth_client.json ("
          <> string.inspect(cause)
          <> "). Create it with your Desktop-app client_id and client_secret."
        client_store.Corrupted ->
          config_dir
          <> "/oauth_client.json must be JSON with client_id and client_secret"
      }
    }),
  )

  let verifier = pkce.generate_verifier()
  let state = pkce.generate_verifier()
  use #(listener, port) <- result.try(loopback.open_listener(0))

  io.println("Open this URL in your browser to authorize iaragon:")
  io.println("")
  io.println(oauth.build_authorization_url(
    client,
    redirect_port: port,
    challenge: pkce.derive_challenge(verifier),
    state: state,
  ))
  io.println("")
  io.println(
    "Waiting for the redirect on http://127.0.0.1:"
    <> int.to_string(port)
    <> " (up to 5 minutes)…",
  )

  use code <- result.try(
    loopback.await_authorization(listener, redirect_timeout_ms, state)
    |> result.map_error(string.inspect),
  )
  use tokens <- result.try(
    oauth.exchange_code(
      send_over_httpc,
      client,
      redirect_port: port,
      code: code,
      verifier: verifier,
    )
    |> result.map_error(string.inspect),
  )
  use refresh_token <- result.try(case tokens.refresh_token {
    Some(refresh_token) -> Ok(refresh_token)
    None ->
      Error(
        "Google returned no refresh token; revoke the app's access at "
        <> "https://myaccount.google.com/permissions and log in again",
      )
  })

  let now = timestamp.system_time() |> timestamp.to_unix_seconds |> float.round
  let path = config_dir <> "/tokens.json"
  use Nil <- result.try(
    token_store.save_tokens(
      path,
      StoredTokens(
        access_token: tokens.access_token,
        refresh_token: refresh_token,
        expires_at_unix: now + tokens.expires_in_seconds,
      ),
    )
    |> result.map_error(string.inspect),
  )
  Ok(path)
}

fn send_over_httpc(
  request: Request(String),
) -> Result(Response(String), String) {
  httpc.send(request) |> result.map_error(string.inspect)
}
