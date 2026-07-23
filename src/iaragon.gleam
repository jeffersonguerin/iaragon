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
import iaragon/infrastructure/persistence/state_db
import iaragon/infrastructure/supervision
import simplifile

pub fn main() -> Nil {
  let assert Ok(home) = envoy.get("HOME")
  let data_dir = home <> "/.local/share/iaragon"
  let assert Ok(Nil) = simplifile.create_directory_all(data_dir)
  let assert Ok(db) = state_db.open(data_dir <> "/state.db")

  let config_dir = home <> "/.config/iaragon"
  let mirror_root = home <> "/GoogleDrive"
  let assert Ok(daemon) =
    supervision.start_daemon(
      store: state_db.build_state_store(db),
      drive: build_drive_port(config_dir),
      mirror_root: mirror_root,
      transfers: build_transfer_ops(config_dir),
      native_policy: entry.default_native_doc_policy(),
      signal_status: emblems.build_status_painter(mirror_root),
    )
  // Kick the pipeline: seed on the first cycle, then poll every interval.
  process.send(daemon.remote_poller, remote_poller.Poll)
  process.sleep_forever()
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
