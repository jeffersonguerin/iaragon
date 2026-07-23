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
