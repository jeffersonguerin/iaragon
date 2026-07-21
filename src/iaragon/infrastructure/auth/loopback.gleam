//// Captures the OAuth redirect on http://127.0.0.1:{port}. Two phases so
//// the actual port is known BEFORE the browser opens: `open_listener`
//// binds (port 0 = ephemeral), `await_authorization` blocks for the one
//// redirect request, validates the anti-CSRF state and extracts the code.
//// The socket work is a thin Erlang FFI (`iaragon_loopback_ffi`).

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/uri

/// Opaque handle to the bound gen_tcp listen socket.
pub type Listener

pub type AwaitError {
  TransportBroke(reason: String)
  DeniedByUser(error: String)
  MismatchedState
  MalformedRedirect(target: String)
}

@external(erlang, "iaragon_loopback_ffi", "open_listener")
pub fn open_listener(port: Int) -> Result(#(Listener, Int), String)

@external(erlang, "iaragon_loopback_ffi", "await_request")
fn await_request(listener: Listener, timeout_ms: Int) -> Result(String, String)

pub fn await_authorization(
  listener: Listener,
  timeout_ms: Int,
  expected_state expected_state: String,
) -> Result(String, AwaitError) {
  use target <- result.try(
    await_request(listener, timeout_ms) |> result.map_error(TransportBroke),
  )
  parse_redirect(target, expected_state)
}

fn parse_redirect(
  target: String,
  expected_state: String,
) -> Result(String, AwaitError) {
  let params =
    uri.parse(target)
    |> result.map(fn(parsed) { parsed.query })
    |> result.map(fn(query) {
      case query {
        Some(query) -> uri.parse_query(query) |> result.unwrap([])
        None -> []
      }
    })
    |> result.unwrap([])

  let state_matches = list.key_find(params, "state") == Ok(expected_state)
  // Whatever the outcome, it only counts when the anti-CSRF state matches.
  case
    state_matches,
    list.key_find(params, "code"),
    list.key_find(params, "error")
  {
    True, Ok(code), _ -> Ok(code)
    True, _, Ok(error) -> Error(DeniedByUser(error))
    False, Ok(_), _ -> Error(MismatchedState)
    False, _, Ok(_) -> Error(MismatchedState)
    _, _, _ -> Error(MalformedRedirect(target))
  }
}
