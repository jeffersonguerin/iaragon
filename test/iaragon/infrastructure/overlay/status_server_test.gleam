import iaragon/infrastructure/overlay/status_server
import simplifile

// The status server speaks the file-manager plugin protocol over a unix
// domain socket: one absolute path per request line, one status word per
// reply line, many exchanges per connection. The test client is the same
// line protocol the Dolphin plugin uses (QLocalSocket).

@external(erlang, "iaragon_status_client_ffi", "query_lines")
fn query_lines(
  sock_path: String,
  lines: List(String),
) -> Result(List(String), String)

@external(erlang, "iaragon_status_client_ffi", "slam")
fn slam(sock_path: String, times: Int) -> Nil

const sock_dir = "build/test-scratch/status-server"

pub fn each_request_line_gets_its_answer_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  let sock = sock_dir <> "/answers.sock"
  let assert Ok(_) =
    status_server.start(sock, fn(line) {
      case line {
        "/mirror/a.txt" -> "synced"
        "/mirror/b.txt" -> "syncing"
        _ -> "unknown"
      }
    })

  // Several exchanges over ONE connection — the plugin keeps its socket.
  assert query_lines(sock, ["/mirror/a.txt", "/mirror/b.txt", "/elsewhere"])
    == Ok(["synced", "syncing", "unknown"])
}

pub fn the_socket_is_owner_only_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  let sock = sock_dir <> "/perms.sock"
  let _ = simplifile.delete(sock)
  let assert Ok(_) = status_server.start(sock, fn(_line) { "synced" })

  let assert Ok(info) = simplifile.file_info(sock)
  // The status protocol reveals which files exist in the mirror, so no
  // other local user may connect.
  assert simplifile.file_info_permissions_octal(info) == 0o600
}

// PENTEST — a local peer (same user; the socket is 0600) that connects and
// aborts repeatedly races the acceptor's controlling_process handoff. If that
// handoff badmatches on the closed socket the acceptor dies, taking the listen
// socket with it. The server must shrug off the barrage and keep answering.
pub fn the_server_survives_a_barrage_of_aborted_connections_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  let sock = sock_dir <> "/barrage.sock"
  let _ = simplifile.delete(sock)
  let assert Ok(_) =
    status_server.start(sock, fn(line) {
      case line {
        "/mirror/a.txt" -> "synced"
        _ -> "unknown"
      }
    })

  slam(sock, 400)

  assert query_lines(sock, ["/mirror/a.txt"]) == Ok(["synced"])
}

pub fn a_stale_socket_file_is_replaced_on_start_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  let sock = sock_dir <> "/stale.sock"
  // Wipe leftovers from earlier runs (a bound socket file rejects write).
  let _ = simplifile.delete(sock)
  // A leftover from a previous daemon run (crash without cleanup).
  let assert Ok(Nil) = simplifile.write(to: sock, contents: "")

  let assert Ok(_) = status_server.start(sock, fn(_line) { "synced" })

  assert query_lines(sock, ["/whatever"]) == Ok(["synced"])
}

// Where the socket lives — ONE resolution shared by the daemon and the
// doctor, matching the Dolphin plugin: the user runtime dir when the session
// provides one, the data dir otherwise. An EMPTY XDG_RUNTIME_DIR counts as
// absent (the plugin's isEmpty check), never as the filesystem root.
pub fn the_socket_path_prefers_the_runtime_dir_test() {
  assert status_server.resolve_socket_path(Ok("/run/user/1000"), "/data")
    == "/run/user/1000/iaragon.sock"
}

pub fn the_socket_path_falls_back_to_the_data_dir_test() {
  assert status_server.resolve_socket_path(Error(Nil), "/data")
    == "/data/status.sock"
}

pub fn an_empty_runtime_dir_counts_as_absent_test() {
  assert status_server.resolve_socket_path(Ok(""), "/data")
    == "/data/status.sock"
}

// A runtime dir with a trailing slash (some sessions set
// XDG_RUNTIME_DIR=/run/user/1000/) must not produce a "//" in the joined
// path — cosmetic, POSIX collapses it, but the reported path must be clean.
pub fn a_trailing_slash_on_the_runtime_dir_is_not_doubled_test() {
  assert status_server.resolve_socket_path(Ok("/run/user/1000/"), "/data")
    == "/run/user/1000/iaragon.sock"
}

pub fn a_trailing_slash_on_the_data_dir_is_not_doubled_test() {
  assert status_server.resolve_socket_path(Error(Nil), "/data/")
    == "/data/status.sock"
}
