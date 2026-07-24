//// The single-instance guard. Two daemons over one mirror silently fight
//// each other — each treats the other's writes as foreign changes,
//// conflicted copies multiply and both upload them (observed live: an
//// orphaned BEAM surviving its wrapper, and two package installs both
//// enabled). Before booting, the daemon asks the status socket the reserved
//// `?status` line: a live answer means another instance owns this mirror
//// and the newcomer must refuse to start.
////
//// A socket FILE with nothing behind it is not an obstacle: nothing
//// answers, the path counts as free, and the status server replaces stale
//// files on bind. The remaining hole is two daemons booting in the same
//// instant (both probe before either binds) — accepted: the observed
//// incidents were sequential starts, never simultaneous ones.

pub type Verdict {
  Free
  /// Something answered the probe; the word is its aggregate status,
  /// reported so the refusal line tells the operator what is running.
  AlreadyRunning(status: String)
}

/// Probe the status socket for a live sibling. The probe is injected (the
/// production one is `status_probe.query_status`) so the verdict logic is
/// testable without a socket.
pub fn detect_running_daemon(
  sock_path: String,
  probe probe: fn(String, String) -> Result(String, String),
) -> Verdict {
  case probe(sock_path, "?status") {
    Ok(status) -> AlreadyRunning(status)
    Error(_nobody_answered) -> Free
  }
}
