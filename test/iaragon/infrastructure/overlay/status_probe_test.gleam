import iaragon/infrastructure/overlay/status_probe
import iaragon/infrastructure/overlay/status_server
import simplifile

// The doctor's liveness probe: one line in, one status word out, over the
// same unix-socket protocol the file-manager plugin speaks. A connection
// refused/missing socket means no daemon is listening there.

const sock_dir = "build/test-scratch/status-probe"

pub fn probing_a_live_server_returns_its_answer_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  let sock = sock_dir <> "/live.sock"
  let _ = simplifile.delete(sock)
  let assert Ok(_) = status_server.start(sock, fn(_line) { "synced" })

  assert status_probe.query_status(sock, "/anything") == Ok("synced")
}

pub fn probing_a_missing_socket_reports_no_daemon_test() {
  let assert Error(_) =
    status_probe.query_status(sock_dir <> "/absent.sock", "/anything")
}
