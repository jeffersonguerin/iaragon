import iaragon/infrastructure/overlay/single_instance.{AlreadyRunning, Free}
import iaragon/infrastructure/overlay/status_probe
import iaragon/infrastructure/overlay/status_server
import simplifile

// Two daemons over one mirror silently fight each other — each treats the
// other's writes as foreign changes, conflicted copies multiply and both
// upload them (observed live, twice). The guard probes the status socket
// before boot: something ALIVE answering there means another instance owns
// the mirror, and the second must refuse to start. A dead socket file is
// NOT an obstacle — the status server replaces stale files on bind.

const sock_dir = "build/test-scratch/single-instance"

pub fn a_live_answer_means_another_instance_test() {
  assert single_instance.detect_running_daemon(
      "/run/user/0/irrelevant.sock",
      probe: fn(_path, _line) { Ok("synced") },
    )
    == AlreadyRunning("synced")
}

pub fn no_answer_means_the_path_is_free_test() {
  assert single_instance.detect_running_daemon(
      "/run/user/0/irrelevant.sock",
      probe: fn(_path, _line) { Error("econnrefused") },
    )
    == Free
}

// The real seam: a LIVE status server on a real unix socket must be
// detected through the real probe FFI — and the reserved `?status` line is
// what gets asked, so the guard sees the daemon's aggregate word.
pub fn a_real_daemon_socket_is_detected_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  let sock = sock_dir <> "/live.sock"
  let assert Ok(_) = status_server.start(sock, fn(_line) { "syncing" })

  assert single_instance.detect_running_daemon(
      sock,
      probe: status_probe.query_status,
    )
    == AlreadyRunning("syncing")
}

pub fn an_absent_socket_is_free_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  assert single_instance.detect_running_daemon(
      sock_dir <> "/nobody-here.sock",
      probe: status_probe.query_status,
    )
    == Free
}

// A leftover FILE with no listener (a crashed daemon's residue) must not
// block a boot: nothing answers, so the path counts as free and the status
// server's replace-on-bind takes it from there.
pub fn a_stale_socket_file_is_free_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(sock_dir)
  let stale = sock_dir <> "/stale.sock"
  let assert Ok(Nil) = simplifile.write(to: stale, contents: "")

  assert single_instance.detect_running_daemon(
      stale,
      probe: status_probe.query_status,
    )
    == Free
}
