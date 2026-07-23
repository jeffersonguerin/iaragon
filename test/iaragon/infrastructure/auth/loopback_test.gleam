import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/string
import iaragon/infrastructure/auth/loopback

// These tests exercise the real gen_tcp listener with a real local HTTP
// request, sent from a second process because await blocks.

fn browse_back(port: Int, query: String) -> Nil {
  process.spawn(fn() {
    let assert Ok(request) =
      request.to("http://127.0.0.1:" <> int.to_string(port) <> "/?" <> query)
    let _ = httpc.send(request)
    Nil
  })
  Nil
}

pub fn captures_the_code_from_the_browser_redirect_test() {
  let assert Ok(#(listener, port)) = loopback.open_listener(0)
  browse_back(port, "code=code-7&state=st-1")
  assert loopback.await_authorization(listener, 5000, expected_state: "st-1")
    == Ok("code-7")
}

pub fn rejects_a_redirect_with_the_wrong_state_test() {
  let assert Ok(#(listener, port)) = loopback.open_listener(0)
  browse_back(port, "code=code-7&state=evil")
  assert loopback.await_authorization(listener, 5000, expected_state: "st-1")
    == Error(loopback.MismatchedState)
}

pub fn reports_the_user_denying_access_test() {
  let assert Ok(#(listener, port)) = loopback.open_listener(0)
  browse_back(port, "error=access_denied&state=st-1")
  assert loopback.await_authorization(listener, 5000, expected_state: "st-1")
    == Error(loopback.DeniedByUser("access_denied"))
}

pub fn reports_a_redirect_without_code_or_error_test() {
  let assert Ok(#(listener, port)) = loopback.open_listener(0)
  browse_back(port, "unrelated=1")
  let assert Error(loopback.MalformedRedirect(_)) =
    loopback.await_authorization(listener, 5000, expected_state: "st-1")
}

// PENTEST — any local process can connect to the ephemeral loopback port
// during the login window. Without a bound on the request line, streaming a
// multi-megabyte URI grows the driver buffer until the login process runs out
// of memory. The listener must cap the line and refuse the over-long request
// cleanly instead of accepting (or buffering) it — even though this one
// carries an otherwise-valid state+code.
pub fn refuses_an_oversized_request_line_test() {
  let assert Ok(#(listener, port)) = loopback.open_listener(0)
  let flood = string.repeat("A", 20_000)
  // Unlinked: once the server caps the line it closes without an HTTP
  // response, so the client crashes on the broken socket — that is expected
  // and must not propagate into the test runner.
  process.spawn_unlinked(fn() {
    let assert Ok(request) =
      request.to(
        "http://127.0.0.1:"
        <> int.to_string(port)
        <> "/?code=code-7&state=st-1&x="
        <> flood,
      )
    let _ = httpc.send(request)
    Nil
  })
  let assert Error(loopback.TransportBroke(_)) =
    loopback.await_authorization(listener, 5000, expected_state: "st-1")
}
