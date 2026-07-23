import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import iaragon/application/reconciler
import iaragon/domain/entry
import iaragon/infrastructure/drive/changes
import iaragon/infrastructure/drive/download
import iaragon/infrastructure/drive/listing
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/transfer_pool
import iaragon/infrastructure/drive/upload
import iaragon/infrastructure/supervision
import simplifile
import support/fakes

// End to end, no credentials, no network: Google ships no Drive API
// sandbox/emulator, so a local fake speaks the REAL wire protocol (verified
// JSON shapes, resumable upload session, alt=media download) and the REAL
// daemon tree runs against it — real httpc, real parsers, real streaming
// download FFI, real supervision. The only test seams are the ones
// production already has: the injected send functions (rewritten to point
// at 127.0.0.1) and the transfer URLs (built against the fake's port).

@external(erlang, "iaragon_fake_drive_ffi", "start_server")
fn start_fake_drive(
  handle: fn(String, String, BitArray) ->
    #(Int, List(#(String, String)), String),
) -> Int

const mirror_root = "build/test-scratch/e2e-mirror"

const remote_content = "hello from drive"

pub fn the_whole_daemon_syncs_both_ways_against_a_fake_drive_test() {
  let _ = simplifile.delete(mirror_root)
  let assert Ok(Nil) = simplifile.create_directory_all(mirror_root)
  let uploads = process.new_subject()
  let port =
    start_fake_drive(fn(method, target, body) {
      route(method, target, body, uploads)
    })

  let assert Ok(daemon) =
    supervision.start_daemon(
      store: fakes.an_ephemeral_store(),
      drive: build_drive_port(port),
      mirror_root: mirror_root,
      transfers: build_transfer_ops(port),
      native_policy: entry.default_native_doc_policy(),
      signal_status: fn(_path, _status) { Nil },
      status_socket_path: "build/test-scratch/e2e-status.sock",
    )

  // Remote → local: the self-kicked first cycle seeds and downloads the
  // remote file into the mirror through the real streaming FFI.
  assert fakes.retry_until(80, fn() {
    simplifile.read(mirror_root <> "/hello.txt") == Ok(remote_content)
  })

  // Local → remote: a new local file is picked up by a round and uploaded
  // through the real resumable-session client; the fake records the bytes.
  let local_content = "written locally"
  let assert Ok(Nil) =
    simplifile.write(to: mirror_root <> "/note.txt", contents: local_content)
  process.send(daemon.reconciler, reconciler.ReconcileNow)

  let assert Ok(received) = process.receive(uploads, 5000)
  assert received == local_content

  // And the tree is still standing after the full exchange.
  assert process.subject_owner(daemon.reconciler) != Error(Nil)
}

// --- fake Drive routing ------------------------------------------------

fn route(
  method: String,
  target: String,
  body: BitArray,
  uploads: process.Subject(String),
) -> #(Int, List(#(String, String)), String) {
  case method, target {
    "GET", "/drive/v3/changes/startPageToken" <> _ ->
      json_response("{\"startPageToken\":\"t-1\"}")
    "GET", "/drive/v3/changes" <> _ ->
      json_response("{\"changes\":[],\"newStartPageToken\":\"t-1\"}")
    "GET", "/drive/v3/files/root" <> _ -> json_response("{\"id\":\"root-1\"}")
    "GET", "/drive/v3/files/id-hello" <> _ -> #(200, [], remote_content)
    "GET", "/drive/v3/files" <> _ -> json_response(listing_page())
    // Resumable upload: initiate → Location (validated by the client as a
    // googleapis host, then rewritten to us by the send function) → PUT.
    "POST", "/upload/drive/v3/files" <> _ -> #(
      200,
      [#("Location", "https://www.googleapis.com/fake-session-1")],
      "",
    )
    "PUT", "/fake-session-1" <> _ -> {
      let content = bit_array.to_string(body) |> result.unwrap("")
      process.send(uploads, content)
      json_response(uploaded_file_metadata(content))
    }
    _, _ -> #(404, [], "unexpected " <> method <> " " <> target)
  }
}

fn json_response(body: String) -> #(Int, List(#(String, String)), String) {
  #(200, [#("Content-Type", "application/json")], body)
}

fn listing_page() -> String {
  // Drive serialises int64 fields (size) as JSON strings; md5 is lowercase
  // hex. Both consistent with the actual bytes so later rounds are Noops.
  "{\"files\":[{"
  <> "\"id\":\"id-hello\",\"name\":\"hello.txt\","
  <> "\"mimeType\":\"text/plain\",\"parents\":[\"root-1\"],"
  <> "\"modifiedTime\":\"2026-07-01T10:00:00.000Z\","
  <> "\"size\":\""
  <> int.to_string(string.byte_size(remote_content))
  <> "\","
  <> "\"md5Checksum\":\""
  <> md5_hex(remote_content)
  <> "\","
  <> "\"trashed\":false}]}"
}

fn uploaded_file_metadata(content: String) -> String {
  "{\"id\":\"id-note\",\"name\":\"note.txt\","
  <> "\"mimeType\":\"text/plain\",\"parents\":[\"root-1\"],"
  <> "\"modifiedTime\":\"2026-07-02T10:00:00.000Z\","
  <> "\"size\":\""
  <> int.to_string(string.byte_size(content))
  <> "\","
  <> "\"md5Checksum\":\""
  <> md5_hex(content)
  <> "\","
  <> "\"trashed\":false}"
}

fn md5_hex(content: String) -> String {
  crypto.hash(crypto.Md5, bit_array.from_string(content))
  |> bit_array.base16_encode
  |> string.lowercase
}

// --- real clients pointed at the fake ----------------------------------

/// The same send the composition root injects, with one difference: the
/// request is redirected to the fake's loopback port. Everything after the
/// injection seam — httpc, TLS-less TCP, parsers — is the production path.
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

fn send_bits_to_fake(
  port: Int,
) -> fn(Request(BitArray)) -> Result(Response(String), String) {
  fn(req) {
    use response <- result.try(
      request.Request(
        ..req,
        scheme: http.Http,
        host: "127.0.0.1",
        port: Some(port),
      )
      |> httpc.send_bits
      |> result.map_error(string.inspect),
    )
    use body <- result.try(
      bit_array.to_string(response.body)
      |> result.replace_error("non-utf8 response body"),
    )
    Ok(response.Response(..response, body: body))
  }
}

fn build_drive_port(port: Int) -> remote_poller.DrivePort {
  let send = send_to_fake(port)
  remote_poller.DrivePort(
    fetch_start_page_token: fn() {
      changes.fetch_start_page_token(send, "e2e-token")
      |> result.map_error(string.inspect)
    },
    fetch_mirror_snapshot: fn() {
      use root_id <- result.try(
        listing.fetch_root_id(send, "e2e-token")
        |> result.map_error(string.inspect),
      )
      use files <- result.try(
        listing.fetch_full_listing(send, "e2e-token")
        |> result.map_error(string.inspect),
      )
      Ok(#(root_id, list_map_sightings(files)))
    },
    fetch_all_changes: fn(page_token) {
      changes.fetch_all_changes(send, "e2e-token", page_token)
      |> result.map_error(fn(error) {
        remote_poller.ChangesFailed(string.inspect(error))
      })
    },
  )
}

fn list_map_sightings(
  files: List(changes.ChangedFile),
) -> List(reconciler.RemoteSighting) {
  case files {
    [] -> []
    [file, ..rest] -> [
      remote_poller.translate_file(file),
      ..list_map_sightings(rest)
    ]
  }
}

fn build_transfer_ops(port: Int) -> transfer_pool.DriveTransferOps {
  let send_bits = send_bits_to_fake(port)
  let base = "http://127.0.0.1:" <> int.to_string(port)
  transfer_pool.DriveTransferOps(
    fetch_to_disk: fn(file_id, destination) {
      download.fetch_file_to_disk(
        url: base <> "/drive/v3/files/" <> file_id <> "?alt=media",
        access_token: "e2e-token",
        destination: destination,
        timeout_ms: 10_000,
      )
      |> result.map_error(string.inspect)
    },
    upload_to_drive: fn(target, source, size) {
      upload.upload_file(
        send_bits,
        access_token: "e2e-token",
        target: target,
        source_path: source,
        total_size: size,
        chunk_size: 262_144,
      )
      |> result.map_error(string.inspect)
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
