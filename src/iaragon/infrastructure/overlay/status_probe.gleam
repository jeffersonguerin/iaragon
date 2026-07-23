//// The doctor's client side of the status socket: one path line in, one
//// status word out. An error (no socket file, connection refused) means no
//// daemon is answering there — which is itself the diagnostic signal.

@external(erlang, "iaragon_probe_ffi", "query_status_line")
pub fn query_status(sock_path: String, line: String) -> Result(String, String)
