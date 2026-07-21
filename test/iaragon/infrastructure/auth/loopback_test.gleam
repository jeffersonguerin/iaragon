import gleam/erlang/process
import gleam/http/request
import gleam/httpc
import gleam/int
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
