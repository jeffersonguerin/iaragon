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
import gleam/string

@external(erlang, "iaragon_status_ffi", "serve_status_lines")
fn serve_status_lines(
  sock_path: String,
  answer: fn(String) -> String,
) -> Result(Pid, String)

/// Where the socket lives — the ONE resolution shared by the daemon and the
/// doctor, mirroring the Dolphin plugin: the user runtime dir when the
/// session provides one, the data dir otherwise. An empty XDG_RUNTIME_DIR
/// counts as absent (the plugin's isEmpty check) — never the filesystem
/// root. Keep in sync with integrations/dolphin.
pub fn resolve_socket_path(
  runtime_dir: Result(String, Nil),
  data_dir: String,
) -> String {
  case runtime_dir {
    Ok("") | Error(Nil) -> join(data_dir, "status.sock")
    Ok(dir) -> join(dir, "iaragon.sock")
  }
}

/// Join a directory and a leaf with exactly one separator — a trailing
/// slash on the directory (some sessions export XDG_RUNTIME_DIR with one)
/// must not become "//" in the path we report.
fn join(dir: String, leaf: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> leaf
    False -> dir <> "/" <> leaf
  }
}

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
