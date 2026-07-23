import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import iaragon/application/reconciler
import iaragon/domain/entry
import iaragon/infrastructure/drive/changes
import iaragon/infrastructure/drive/download
import iaragon/infrastructure/drive/listing
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/transfer_pool
import iaragon/infrastructure/supervision
import simplifile
import support/fakes

// Pipeline performance: what the per-file overhead of the WHOLE tree looks
// like (poller → reconciler → serial transfer pool → state owner), measured
// by converging a 1,000-file fake Drive into an empty mirror; plus the
// exact heap cost of the in-memory remote model at 100k files.

@external(erlang, "iaragon_fake_drive_ffi", "start_server")
fn start_fake_drive(
  handle: fn(String, String, BitArray) ->
    #(Int, List(#(String, String)), String),
) -> Int

@external(erlang, "iaragon_bench_ffi", "deep_size_bytes")
fn deep_size_bytes(term: a) -> Int

const mirror_root = "build/test-scratch/perf-pipeline-mirror"

const file_count = 1000

fn now_ms() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds
  |> fn(seconds) { float.round(seconds *. 1000.0) }
}

pub fn a_thousand_remote_files_converge_through_the_real_tree_test() {
  let _ = simplifile.delete(mirror_root)
  let assert Ok(Nil) = simplifile.create_directory_all(mirror_root)
  let port =
    start_fake_drive(fn(method, target, body) { route(method, target, body) })

  let started = now_ms()
  let assert Ok(_daemon) =
    supervision.start_daemon(
      store: fakes.an_ephemeral_store(),
      drive: build_drive_port(port),
      mirror_root: mirror_root,
      transfers: build_transfer_ops(port),
      native_policy: entry.default_native_doc_policy(),
      signal_status: fn(_path, _status) { Nil },
      status_socket_path: "build/test-scratch/perf-pipeline-status.sock",
    )

  // Converged = every file present with its exact bytes (sampling first and
  // last is enough to prove ordering-independent completion, plus a count).
  assert fakes.retry_until(600, fn() {
    count_mirror_files() == file_count
    && simplifile.read(mirror_root <> "/file1.txt") == Ok(content_of(1))
    && simplifile.read(
      mirror_root <> "/file" <> int.to_string(file_count) <> ".txt",
    )
    == Ok(content_of(file_count))
  })
  let elapsed = now_ms() - started
  io.println(
    "  [perf] pipeline: 1000-file seed to converged mirror in "
    <> int.to_string(elapsed)
    <> " ms ("
    <> int.to_string(elapsed / file_count)
    <> " ms/file, serial pool over loopback)",
  )
  // The pool is serial by design; per-file overhead must stay small enough
  // that a big first sync is minutes, not hours (30 ms/file = 50 min/100k).
  assert elapsed / file_count < 30
}

pub fn the_remote_model_at_100k_files_fits_in_memory_test() {
  // The reconciler holds the remote model as dicts keyed by file_id. Build
  // the same shape at 100k and measure its exact heap footprint.
  let sightings =
    list.map(build_range(100_000, 1, []), fn(n) {
      #(
        "file-id-" <> int.to_string(n),
        reconciler.RemoteSighting(
          file_id: "file-id-" <> int.to_string(n),
          name: "file" <> int.to_string(n) <> ".txt",
          mime_type: "text/plain",
          parent_id: Some("root-1"),
          modified_time: "2026-07-01T10:00:00Z",
          size: Some(42),
          md5: Some("0123456789abcdef0123456789abcdef"),
          shortcut_target_id: None,
          trashed: False,
        ),
      )
    })
  let model = dict.from_list(sightings)
  let megabytes = deep_size_bytes(model) / 1_048_576
  io.println(
    "  [perf] remote model heap at 100k files: "
    <> int.to_string(megabytes)
    <> " MiB",
  )
  assert dict.size(model) == 100_000
  // Canary: the model must stay laptop-friendly at the extreme end.
  assert megabytes < 500
}

// --- fake Drive with 1000 files ------------------------------------------

fn content_of(n: Int) -> String {
  "content of remote file number " <> int.to_string(n)
}

fn route(
  method: String,
  target: String,
  _body: BitArray,
) -> #(Int, List(#(String, String)), String) {
  case method, target {
    "GET", "/drive/v3/changes/startPageToken" <> _ ->
      json_response("{\"startPageToken\":\"t-1\"}")
    "GET", "/drive/v3/changes" <> _ ->
      json_response("{\"changes\":[],\"newStartPageToken\":\"t-1\"}")
    "GET", "/drive/v3/files/root" <> _ -> json_response("{\"id\":\"root-1\"}")
    "GET", "/drive/v3/files/f" <> rest ->
      // Download: /drive/v3/files/f<n>?alt=media
      case
        int.parse(string.split(rest, "?") |> list.first |> result.unwrap(""))
      {
        Ok(n) -> #(200, [], content_of(n))
        Error(Nil) -> #(404, [], "bad id")
      }
    "GET", "/drive/v3/files" <> _ -> json_response(listing_page())
    _, _ -> #(404, [], "unexpected " <> method <> " " <> target)
  }
}

fn json_response(body: String) -> #(Int, List(#(String, String)), String) {
  #(200, [#("Content-Type", "application/json")], body)
}

fn listing_page() -> String {
  let files =
    build_range(file_count, 1, [])
    |> list.map(fn(n) {
      let content = content_of(n)
      "{\"id\":\"f"
      <> int.to_string(n)
      <> "\",\"name\":\"file"
      <> int.to_string(n)
      <> ".txt\",\"mimeType\":\"text/plain\",\"parents\":[\"root-1\"],"
      <> "\"modifiedTime\":\"2026-07-01T10:00:00.000Z\","
      <> "\"size\":\""
      <> int.to_string(string.byte_size(content))
      <> "\",\"md5Checksum\":\""
      <> md5_hex(content)
      <> "\",\"trashed\":false}"
    })
    |> string.join(",")
  "{\"files\":[" <> files <> "]}"
}

fn md5_hex(content: String) -> String {
  crypto.hash(crypto.Md5, bit_array.from_string(content))
  |> bit_array.base16_encode
  |> string.lowercase
}

fn count_mirror_files() -> Int {
  case simplifile.read_directory(mirror_root) {
    Ok(entries) ->
      list.count(entries, fn(name) { string.ends_with(name, ".txt") })
    Error(_) -> 0
  }
}

// --- real clients pointed at the fake (same seams as production) ----------

fn send_to_fake(
  port: Int,
) -> fn(Request(String)) -> Result(Response(String), String) {
  fn(req) {
    request.Request(
      ..req,
      scheme: http.Http,
      host: "127.0.0.1",
      port: Some(port),
    )
    |> httpc.send
    |> result.map_error(string.inspect)
  }
}

fn build_drive_port(port: Int) -> remote_poller.DrivePort {
  let send = send_to_fake(port)
  remote_poller.DrivePort(
    fetch_start_page_token: fn() {
      changes.fetch_start_page_token(send, "perf-token")
      |> result.map_error(string.inspect)
    },
    fetch_mirror_snapshot: fn() {
      use root_id <- result.try(
        listing.fetch_root_id(send, "perf-token")
        |> result.map_error(string.inspect),
      )
      use files <- result.try(
        listing.fetch_full_listing(send, "perf-token")
        |> result.map_error(string.inspect),
      )
      Ok(#(root_id, list.map(files, remote_poller.translate_file)))
    },
    fetch_all_changes: fn(page_token) {
      changes.fetch_all_changes(send, "perf-token", page_token)
      |> result.map_error(fn(error) {
        remote_poller.ChangesFailed(string.inspect(error))
      })
    },
  )
}

fn build_transfer_ops(port: Int) -> transfer_pool.DriveTransferOps {
  let base = "http://127.0.0.1:" <> int.to_string(port)
  transfer_pool.DriveTransferOps(
    fetch_to_disk: fn(file_id, destination) {
      download.fetch_file_to_disk(
        url: base <> "/drive/v3/files/" <> file_id <> "?alt=media",
        access_token: "perf-token",
        destination: destination,
        timeout_ms: 10_000,
      )
      |> result.map_error(string.inspect)
    },
    upload_to_drive: fn(_target, _source, _size) {
      Error("no uploads in this scenario")
    },
    create_remote_folder: fn(_name, _parent_id) {
      Error("no folders in this scenario")
    },
    trash_remote: fn(_file_id) { Error("no trash in this scenario") },
    rename_remote: fn(_id, _name, _add, _remove) {
      Error("no renames in this scenario")
    },
    export_to_disk: fn(_id, _mime, _destination) {
      Error("no exports in this scenario")
    },
  )
}

fn build_range(current: Int, floor: Int, acc: List(Int)) -> List(Int) {
  case current < floor {
    True -> acc
    False -> build_range(current - 1, floor, [current, ..acc])
  }
}
