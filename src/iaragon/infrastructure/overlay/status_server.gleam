//// The file-manager status endpoint: a unix-domain-socket server speaking
//// one request line (an absolute path) to one reply line (a status word),
//// many exchanges per connection. The Dolphin KOverlayIconPlugin is its
//// client; anything that can write a line to a socket can be.
////
//// The actor exists to own the listen socket under supervision: if it (or
//// the acceptor it is linked to) dies, the supervisor restarts it and the
//// socket is re-bound — stale socket files from crashed runs are replaced
//// on bind.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result

@external(erlang, "iaragon_status_ffi", "serve_status_lines")
fn serve_status_lines(
  sock_path: String,
  answer: fn(String) -> String,
) -> Result(Pid, String)

pub fn supervised(
  sock_path: String,
  answer: fn(String) -> String,
) -> ChildSpecification(Subject(Nil)) {
  supervision.worker(fn() { start(sock_path, answer) })
}

pub fn start(
  sock_path: String,
  answer: fn(String) -> String,
) -> actor.StartResult(Subject(Nil)) {
  actor.new_with_initialiser(1000, fn(subject) {
    use _acceptor <- result.try(serve_status_lines(sock_path, answer))
    actor.initialised(Nil)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(state, _message) { actor.continue(state) })
  |> actor.start
}
