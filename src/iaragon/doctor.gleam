//// Health check for the installed daemon: `iaragon-doctor` (or
//// `gleam run -m iaragon/doctor`). Entirely passive — reads config/state
//// files and makes one query to the status socket — so it never disturbs a
//// running daemon. The only network use is the token refresh the daemon
//// would do anyway on its next API call, and only when the stored access
//// token is already inside the expiry margin.
////
//// Thin composition of tested pieces (client_store, token_store,
//// token_manager, state_db, status_probe, diagnostics) in the same spirit
//// as iaragon/login: no logic of its own to unit-test. Exits non-zero on
//// any failed check, so a systemd timer run shows up red in the journal.

import envoy
import gleam/float
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import iaragon/application/diagnostics.{Check, Fail, Pass, Warn}
import iaragon/infrastructure/auth/client_store
import iaragon/infrastructure/auth/oauth
import iaragon/infrastructure/auth/token_manager
import iaragon/infrastructure/auth/token_store
import iaragon/infrastructure/fs/local_watcher
import iaragon/infrastructure/overlay/status_probe
import iaragon/infrastructure/overlay/status_server
import iaragon/infrastructure/persistence/state_db
import simplifile

pub fn main() -> Nil {
  configure_unicode_stdio()
  case envoy.get("HOME") {
    Error(Nil) -> {
      io.println_error("doctor: HOME is not set")
      halt_with_code(1)
    }
    Ok(home) -> {
      let checks = run_checks(home)
      io.println(diagnostics.render_report(checks))
      case diagnostics.has_failure(checks) {
        True -> halt_with_code(1)
        False -> Nil
      }
    }
  }
}

fn run_checks(home: String) -> List(diagnostics.Check) {
  let config_dir = home <> "/.config/iaragon"
  let data_dir = home <> "/.local/share/iaragon"
  let mirror_root = home <> "/GoogleDrive"
  let client = client_store.load_client(config_dir <> "/oauth_client.json")
  [
    check_client(home, config_dir, client),
    check_tokens(home, config_dir, client),
    check_state(home, data_dir),
    check_daemon(home, data_dir),
    check_mirror(home, mirror_root),
    check_watcher(),
  ]
}

fn check_client(
  home: String,
  config_dir: String,
  client: Result(a, client_store.LoadError),
) -> diagnostics.Check {
  let path = tilde(home, config_dir <> "/oauth_client.json")
  case client {
    Ok(_) -> Check("oauth client", Pass, "configured (" <> path <> ")")
    Error(client_store.Unreadable(_)) ->
      Check(
        "oauth client",
        Fail,
        "missing — create " <> path <> " (see the README) and run iaragon-login",
      )
    Error(client_store.Corrupted) ->
      Check(
        "oauth client",
        Fail,
        path <> " is not JSON with client_id and client_secret",
      )
  }
}

fn check_tokens(
  home: String,
  config_dir: String,
  client: Result(oauth.OauthClient, client_store.LoadError),
) -> diagnostics.Check {
  let tokens_path = config_dir <> "/tokens.json"
  case token_store.load_tokens(tokens_path) {
    Error(token_store.Unreadable(_)) ->
      Check("tokens", Fail, "no login yet — run iaragon-login")
    Error(token_store.Corrupted) ->
      Check(
        "tokens",
        Fail,
        tilde(home, tokens_path) <> " is corrupted — run iaragon-login again",
      )
    Ok(_) ->
      case client {
        // Without a client there is no way to exercise the refresh; the
        // failed client check already tells the user what to fix first.
        Error(_) -> Check("tokens", Warn, "cannot verify without oauth client")
        Ok(client) -> check_refresh(client, tokens_path)
      }
  }
}

/// The live check: hand out an access token exactly like the daemon would.
/// A stored token still outside the expiry margin costs no network at all;
/// one inside the margin exercises the real refresh — which is what detects
/// a dead refresh token (the 7-day "Testing" expiry) before the sync stalls.
fn check_refresh(
  client: oauth.OauthClient,
  tokens_path: String,
) -> diagnostics.Check {
  let source =
    token_manager.TokenSource(
      send: send_over_httpc,
      client: client,
      tokens_path: tokens_path,
      clock: now_unix,
    )
  case token_manager.obtain_access_token(source) {
    Error(token_manager.MissingLogin(_)) ->
      Check("tokens", Fail, "no login yet — run iaragon-login")
    Error(token_manager.RefreshFailed(_)) ->
      Check(
        "tokens",
        Fail,
        "token refresh failed — if the app is in \"Testing\" the refresh "
          <> "token dies after 7 days; run iaragon-login again "
          <> "(publish the app \"In production\" to stop this)",
      )
    Ok(_) ->
      case token_store.load_tokens(tokens_path) {
        Ok(stored) ->
          Check(
            "tokens",
            Pass,
            diagnostics.describe_token_expiry(
              now: now_unix(),
              expires_at: stored.expires_at_unix,
            ),
          )
        Error(_) -> Check("tokens", Pass, "refresh works")
      }
  }
}

fn check_state(home: String, data_dir: String) -> diagnostics.Check {
  let db_path = data_dir <> "/state.db"
  case simplifile.is_file(db_path) {
    Ok(True) ->
      case state_db.open(db_path) {
        Error(_) ->
          Check(
            "state",
            Warn,
            "could not read " <> tilde(home, db_path) <> " (busy?)",
          )
        Ok(db) -> {
          let indexed = case state_db.count_known(db) {
            Ok(total) -> int.to_string(total) <> " files indexed"
            Error(_) -> "index unreadable"
          }
          let token = case state_db.load_page_token(db) {
            Ok(Some(_)) -> "page token present"
            Ok(None) | Error(_) -> "no page token yet"
          }
          Check("state", Pass, indexed <> "; " <> token)
        }
      }
    Ok(False) | Error(_) ->
      Check("state", Warn, "no state yet — the daemon has not synced")
  }
}

fn check_daemon(home: String, data_dir: String) -> diagnostics.Check {
  // The same resolution as the daemon and the Dolphin plugin, so the doctor
  // looks where the daemon actually binds.
  let sock =
    status_server.resolve_socket_path(envoy.get("XDG_RUNTIME_DIR"), data_dir)
  case status_probe.query_status(sock, "/") {
    Ok(_) -> Check("daemon", Pass, "answering on " <> tilde(home, sock))
    Error(_) ->
      Check(
        "daemon",
        Warn,
        "not answering on "
          <> tilde(home, sock)
          <> " — start it with: systemctl --user start iaragon",
      )
  }
}

fn check_mirror(home: String, mirror_root: String) -> diagnostics.Check {
  case simplifile.is_directory(mirror_root) {
    Ok(True) -> Check("mirror", Pass, tilde(home, mirror_root) <> " exists")
    Ok(False) | Error(_) ->
      Check(
        "mirror",
        Warn,
        tilde(home, mirror_root) <> " missing — created on first sync",
      )
  }
}

fn check_watcher() -> diagnostics.Check {
  case local_watcher.detect_inotify_support() {
    True -> Check("watcher", Pass, "inotifywait found (real-time events)")
    False ->
      Check(
        "watcher",
        Warn,
        "inotify-tools not found — local changes detected by polling",
      )
  }
}

fn now_unix() -> Int {
  timestamp.system_time() |> timestamp.to_unix_seconds |> float.round
}

fn tilde(home: String, path: String) -> String {
  string.replace(in: path, each: home, with: "~")
}

fn send_over_httpc(
  request: Request(String),
) -> Result(Response(String), String) {
  httpc.send(request) |> result.map_error(string.inspect)
}

@external(erlang, "iaragon_probe_ffi", "halt_with_code")
fn halt_with_code(code: Int) -> Nil

@external(erlang, "iaragon_probe_ffi", "configure_unicode_stdio")
fn configure_unicode_stdio() -> Nil
