import gleam/int
import iaragon/infrastructure/drive/download
import simplifile

// The FFI streams response bodies straight to disk through Erlang's httpc —
// the whole point is never holding a large file in memory (gleam_httpc cannot
// stream). These tests run against a real local one-shot HTTP server.

@external(erlang, "iaragon_serve_once_ffi", "serve_once")
fn serve_once(status: Int, body: String) -> Int

const scratch_dir = "build/test-scratch/download"

fn a_local_url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/files/id-1?alt=media"
}

pub fn bytes_are_streamed_to_the_destination_file_test() {
  let port = serve_once(200, "hello bytes")
  let destination = scratch_dir <> "/plain/report.txt"
  assert download.fetch_file_to_disk(
      url: a_local_url(port),
      access_token: "at-1",
      destination: destination,
      timeout_ms: 5000,
    )
    == Ok(Nil)
  assert simplifile.read(destination) == Ok("hello bytes")
}

pub fn missing_parent_directories_are_created_test() {
  let port = serve_once(200, "nested")
  let destination = scratch_dir <> "/deep/er/still/file.bin"
  assert download.fetch_file_to_disk(
      url: a_local_url(port),
      access_token: "at-1",
      destination: destination,
      timeout_ms: 5000,
    )
    == Ok(Nil)
  assert simplifile.read(destination) == Ok("nested")
}

pub fn redownloading_replaces_the_previous_content_test() {
  // Erlang's httpc {stream, path} APPENDS to an existing file — caught live
  // when this suite ran twice. Downloads must go to a partial file that is
  // renamed over the destination.
  let destination = scratch_dir <> "/replace/report.txt"
  let first = serve_once(200, "first")
  let assert Ok(Nil) =
    download.fetch_file_to_disk(
      url: a_local_url(first),
      access_token: "at-1",
      destination: destination,
      timeout_ms: 5000,
    )
  let second = serve_once(200, "second")
  let assert Ok(Nil) =
    download.fetch_file_to_disk(
      url: a_local_url(second),
      access_token: "at-1",
      destination: destination,
      timeout_ms: 5000,
    )
  assert simplifile.read(destination) == Ok("second")
}

pub fn a_refusal_reports_the_status_and_writes_nothing_test() {
  let port = serve_once(404, "not found")
  let destination = scratch_dir <> "/refused/report.txt"
  assert download.fetch_file_to_disk(
      url: a_local_url(port),
      access_token: "at-1",
      destination: destination,
      timeout_ms: 5000,
    )
    == Error(download.RefusedByServer(404))
  assert simplifile.is_file(destination) == Ok(False)
}

pub fn an_unreachable_server_reports_transport_failure_test() {
  // Nothing listens on the loopback port below (serve_once was never called).
  let assert Error(download.TransportFailed(_)) =
    download.fetch_file_to_disk(
      url: "http://127.0.0.1:1/nope",
      access_token: "at-1",
      destination: scratch_dir <> "/never.txt",
      timeout_ms: 2000,
    )
}

pub fn media_urls_point_at_the_files_endpoint_test() {
  assert download.build_media_url("id-42")
    == "https://www.googleapis.com/drive/v3/files/id-42?alt=media"
}
