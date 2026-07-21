//// Composition root: build the concrete adapters (SQLite store, Drive port
//// authenticated by the token manager over httpc) and start the tree.
////
//// The Drive port loads credentials lazily on every call, so the daemon
//// boots fine before the user has run `gleam run -m iaragon/login` — polls
//// simply fail (and retry) until tokens exist.

import envoy
import gleam/erlang/process
import gleam/float
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/result
import gleam/string
import gleam/time/timestamp
import iaragon/domain/entry
import iaragon/infrastructure/auth/client_store
import iaragon/infrastructure/auth/token_manager
import iaragon/infrastructure/drive/changes
import iaragon/infrastructure/drive/download
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/persistence/state_db
import iaragon/infrastructure/supervision
import simplifile

pub fn main() -> Nil {
  let assert Ok(home) = envoy.get("HOME")
  let data_dir = home <> "/.local/share/iaragon"
  let assert Ok(Nil) = simplifile.create_directory_all(data_dir)
  let assert Ok(db) = state_db.open(data_dir <> "/state.db")

  let config_dir = home <> "/.config/iaragon"
  let deliver_changes = process.new_subject()
  let assert Ok(_daemon) =
    supervision.start_daemon(
      store: state_db.build_state_store(db),
      drive: build_drive_port(config_dir),
      deliver_changes: deliver_changes,
      mirror_root: home <> "/GoogleDrive",
      fetch_to_disk: build_fetch_to_disk(config_dir),
      native_policy: entry.default_native_doc_policy(),
    )
  process.sleep_forever()
}

fn build_fetch_to_disk(
  config_dir: String,
) -> fn(String, String) -> Result(Nil, String) {
  fn(file_id, destination) {
    use access_token <- result.try(obtain_access_token(config_dir))
    download.fetch_file_to_disk(
      url: download.build_media_url(file_id),
      access_token: access_token,
      destination: destination,
      timeout_ms: download_timeout_ms,
    )
    |> result.map_error(string.inspect)
  }
}

/// Generous: big files over slow links; the stream writes as it goes.
const download_timeout_ms = 3_600_000

fn build_drive_port(config_dir: String) -> remote_poller.DrivePort {
  remote_poller.DrivePort(
    fetch_start_page_token: fn() {
      use access_token <- result.try(obtain_access_token(config_dir))
      changes.fetch_start_page_token(send_over_httpc, access_token)
      |> result.map_error(string.inspect)
    },
    fetch_all_changes: fn(page_token) {
      use access_token <- result.try(obtain_access_token(config_dir))
      changes.fetch_all_changes(send_over_httpc, access_token, page_token)
      |> result.map_error(string.inspect)
    },
  )
}

fn obtain_access_token(config_dir: String) -> Result(String, String) {
  use client <- result.try(
    client_store.load_client(config_dir <> "/oauth_client.json")
    |> result.map_error(string.inspect),
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
  |> result.map_error(string.inspect)
}

fn send_over_httpc(
  request: Request(String),
) -> Result(Response(String), String) {
  httpc.send(request) |> result.map_error(string.inspect)
}
