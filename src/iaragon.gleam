//// Composition root: build the concrete adapters (SQLite store, Drive port
//// authenticated by the token manager over httpc) and start the tree.
////
//// The Drive port loads credentials lazily on every call, so the daemon
//// boots fine before the user has run `gleam run -m iaragon/login` — polls
//// simply fail (and retry) until tokens exist.

import envoy
import gleam/bit_array
import gleam/erlang/process
import gleam/float
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/time/timestamp
import iaragon/domain/entry
import iaragon/infrastructure/auth/client_store
import iaragon/infrastructure/auth/token_manager
import iaragon/infrastructure/drive/changes
import iaragon/infrastructure/drive/download
import iaragon/infrastructure/drive/listing
import iaragon/infrastructure/drive/mutate
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/transfer_pool
import iaragon/infrastructure/drive/upload
import iaragon/infrastructure/fs/emblems
import iaragon/infrastructure/fs/local_trash
import iaragon/infrastructure/overlay/status_server
import iaragon/infrastructure/persistence/state_db
import iaragon/infrastructure/supervision
import simplifile

@external(erlang, "iaragon_probe_ffi", "halt_with_code")
fn halt_with_code(code: Int) -> Nil

/// Boot preconditions fail as ONE actionable journal line, not a crash dump:
/// under systemd a raw `let assert` means an Erlang crash report plus a
/// restart loop the user has to decode. (The reasons here are filesystem/db
/// errors — never credentials.)
fn require(outcome: Result(a, e), what: String) -> a {
  case outcome {
    Ok(value) -> value
    Error(reason) -> {
      io.println_error(
        "iaragon: cannot start: "
        <> what
        <> " ("
        <> string.inspect(reason)
        <> ")",
      )
      halt_with_code(1)
      panic as "unreachable: halted"
    }
  }
}

pub fn main() -> Nil {
  let home = require(envoy.get("HOME"), "HOME is not set")
  let data_dir = home <> "/.local/share/iaragon"
  let _ =
    require(
      simplifile.create_directory_all(data_dir),
      "cannot create " <> data_dir,
    )
  // Owner-only: the data dir holds the state DB (the whole Drive tree index)
  // and the status socket. 0700 blocks other local users from reaching any of
  // it, regardless of each file's own mode.
  let _ =
    require(
      simplifile.set_permissions_octal(data_dir, 0o700),
      "cannot restrict " <> data_dir,
    )
  let db =
    require(
      state_db.open(data_dir <> "/state.db"),
      "cannot open " <> data_dir <> "/state.db",
    )

  let config_dir = home <> "/.config/iaragon"
  // Same guard as the data dir: the config dir holds oauth_client.json and
  // tokens.json. save_tokens only tightens it when a login writes; a daemon
  // running before (or without) a login would otherwise leave the
  // user-created dir world-readable.
  let _ =
    require(
      client_store.protect_config_dir(config_dir),
      "cannot restrict " <> config_dir,
    )
  let mirror_root = home <> "/GoogleDrive"
  // Retention for the local trash (.iaragon-trash/): entries older than 30
  // days are swept once per boot — never from the sync path.
  local_trash.sweep(
    mirror_root,
    now_unix: timestamp.system_time()
      |> timestamp.to_unix_seconds
      |> float.round,
    retention_seconds: 30 * 86_400,
  )
  let _daemon =
    require(
      supervision.start_daemon(
        store: state_db.build_state_store(db),
        drive: build_drive_port(config_dir),
        mirror_root: mirror_root,
        transfers: build_transfer_ops(config_dir),
        native_policy: entry.default_native_doc_policy(),
        signal_status: emblems.build_status_painter(mirror_root),
        status_socket_path: resolve_status_socket_path(data_dir),
        // The explicit human override for the mass-deletion valve: a round
        // that would delete most of the synced files is refused unless the
        // user restarts with this set (rclone bisync's --force, as an env).
        allow_mass_deletion: envoy.get("IARAGON_ALLOW_MASS_DELETE") == Ok("1"),
      ),
      "the supervision tree failed to start",
    )
  // The poller self-kicks on start (and on every supervisor restart); the
  // daemon just needs to stay alive.
  process.sleep_forever()
}

fn resolve_status_socket_path(data_dir: String) -> String {
  status_server.resolve_socket_path(envoy.get("XDG_RUNTIME_DIR"), data_dir)
}

fn build_transfer_ops(config_dir: String) -> transfer_pool.DriveTransferOps {
  transfer_pool.DriveTransferOps(
    fetch_to_disk: fn(file_id, destination) {
      use access_token <- result.try(obtain_access_token(config_dir))
      download.fetch_file_to_disk(
        url: download.build_media_url(file_id),
        access_token: access_token,
        destination: destination,
        timeout_ms: download_timeout_ms,
      )
      |> result.map_error(string.inspect)
    },
    upload_to_drive: fn(target, source, size) {
      use access_token <- result.try(obtain_access_token(config_dir))
      upload.upload_file(
        send_bits_over_httpc,
        access_token: access_token,
        target: target,
        source_path: source,
        total_size: size,
        chunk_size: upload_chunk_bytes,
      )
      |> result.map_error(string.inspect)
    },
    create_remote_folder: fn(name, parent_id) {
      use access_token <- result.try(obtain_access_token(config_dir))
      mutate.create_folder(
        send_over_httpc,
        access_token: access_token,
        name: name,
        parent_id: parent_id,
      )
      |> result.map_error(string.inspect)
    },
    trash_remote: fn(file_id) {
      use access_token <- result.try(obtain_access_token(config_dir))
      mutate.trash_file(
        send_over_httpc,
        access_token: access_token,
        file_id: file_id,
      )
      |> result.map_error(string.inspect)
    },
    rename_remote: fn(file_id, new_name, add_parent_id, remove_parent_id) {
      use access_token <- result.try(obtain_access_token(config_dir))
      mutate.rename_file(
        send_over_httpc,
        access_token: access_token,
        file_id: file_id,
        new_name: new_name,
        add_parent_id: add_parent_id,
        remove_parent_id: remove_parent_id,
      )
      |> result.map_error(string.inspect)
    },
    export_to_disk: fn(file_id, export_mime, destination) {
      use access_token <- result.try(obtain_access_token(config_dir))
      download.fetch_file_to_disk(
        url: download.build_export_url(file_id, export_mime),
        access_token: access_token,
        destination: destination,
        timeout_ms: download_timeout_ms,
      )
      |> result.map_error(string.inspect)
    },
  )
}

/// Generous: big files over slow links; the stream writes as it goes.
const download_timeout_ms = 3_600_000

/// 32 × 256 KB — resumable chunks must be 256 KB multiples.
const upload_chunk_bytes = 8_388_608

fn send_bits_over_httpc(
  request: Request(BitArray),
) -> Result(Response(String), String) {
  use response <- result.try(
    httpc.send_bits(request) |> result.map_error(string.inspect),
  )
  use body <- result.try(
    bit_array.to_string(response.body)
    |> result.replace_error("non-utf8 response body"),
  )
  Ok(response.Response(..response, body: body))
}

fn build_drive_port(config_dir: String) -> remote_poller.DrivePort {
  remote_poller.DrivePort(
    fetch_start_page_token: fn() {
      use access_token <- result.try(obtain_access_token(config_dir))
      changes.fetch_start_page_token(send_over_httpc, access_token)
      |> result.map_error(string.inspect)
    },
    fetch_mirror_snapshot: fn() {
      use access_token <- result.try(obtain_access_token(config_dir))
      use root_id <- result.try(
        listing.fetch_root_id(send_over_httpc, access_token)
        |> result.map_error(string.inspect),
      )
      use files <- result.try(
        listing.fetch_full_listing(send_over_httpc, access_token)
        |> result.map_error(string.inspect),
      )
      Ok(#(root_id, list.map(files, remote_poller.translate_file)))
    },
    fetch_all_changes: fn(page_token) {
      case obtain_access_token(config_dir) {
        Error(reason) -> Error(remote_poller.ChangesFailed(reason))
        Ok(access_token) ->
          changes.fetch_all_changes(send_over_httpc, access_token, page_token)
          |> result.map_error(classify_changes_error)
      }
    },
  )
}

/// A page token Drive rejects surfaces as HTTP 400 (invalidPageToken) or 410
/// (gone); the request is otherwise fixed and valid, so treat those as a stale
/// token to re-seed. Everything else is a transient failure to retry.
fn classify_changes_error(
  error: changes.DriveError,
) -> remote_poller.ChangesError {
  case error {
    changes.RefusedByServer(400, _body) | changes.RefusedByServer(410, _body) ->
      remote_poller.StalePageToken
    other -> remote_poller.ChangesFailed(string.inspect(other))
  }
}

fn obtain_access_token(config_dir: String) -> Result(String, String) {
  use client <- result.try(
    client_store.load_client(config_dir <> "/oauth_client.json")
    |> result.map_error(fn(_error) {
      "no OAuth client configured — run iaragon-login"
    }),
  )
  token_manager.obtain_access_token(
    token_manager.TokenSource(
      send: send_over_httpc,
      client: client,
      tokens_path: config_dir <> "/tokens.json",
      clock: fn() {
        timestamp.system_time() |> timestamp.to_unix_seconds |> float.round
      },
    ),
  )
  // Human wording here, where the error is born: these strings travel up to
  // the poller's journal line, which must tell the user what to DO.
  |> result.map_error(fn(error) {
    case error {
      token_manager.MissingLogin(_) -> "not logged in — run iaragon-login"
      token_manager.RefreshFailed(detail) ->
        "token refresh failed ("
        <> detail
        <> ") — run iaragon-login again; if the app is in \"Testing\" the"
        <> " login dies every 7 days (publish it \"In production\")"
    }
  })
}

fn send_over_httpc(
  request: Request(String),
) -> Result(Response(String), String) {
  httpc.send(request) |> result.map_error(string.inspect)
}
