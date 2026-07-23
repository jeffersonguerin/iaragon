import gleam/int
import gleam/string
import iaragon/infrastructure/drive/download
import simplifile

// The FFI streams response bodies straight to disk through Erlang's httpc —
// the whole point is never holding a large file in memory (gleam_httpc cannot
// stream). These tests run against a real local one-shot HTTP server.

@external(erlang, "iaragon_serve_once_ffi", "serve_once")
fn serve_once(status: Int, body: String) -> Int

@external(erlang, "iaragon_serve_once_ffi", "serve_redirect")
fn serve_redirect(location: String) -> Int

@external(erlang, "iaragon_serve_once_ffi", "serve_auth_reporting")
fn serve_auth_reporting() -> Int

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

// Sanity check for the redirect pentest below: the auth-reporting server
// really does detect the header — a DIRECT download (no redirect) carries the
// bearer, so the body must be "leaked-auth". Without this, "no-auth" in the
// redirect test could be a false negative from broken header detection.
pub fn the_direct_request_carries_the_bearer_test() {
  let port = serve_auth_reporting()
  let destination = scratch_dir <> "/direct-auth/report.txt"
  let assert Ok(Nil) =
    download.fetch_file_to_disk(
      url: "http://127.0.0.1:" <> int.to_string(port) <> "/files/id-1?alt=media",
      access_token: "at-1",
      destination: destination,
      timeout_ms: 5000,
    )
  assert simplifile.read(destination) == Ok("leaked-auth")
}

// PENTEST — a download carries the Bearer token in its Authorization header.
// If a redirect were followed with that header, the credential would travel
// to the redirect target. The FFI must follow redirects WITHOUT forwarding
// the Authorization header (a Drive alt=media 302 goes to a signed URL that
// needs no bearer), so the token never leaves the initial Google host.
pub fn a_redirect_is_followed_without_forwarding_the_bearer_test() {
  let target_port = serve_auth_reporting()
  let target_url =
    "http://127.0.0.1:" <> int.to_string(target_port) <> "/signed-download"
  let redirect_port = serve_redirect(target_url)
  let destination = scratch_dir <> "/redirect/report.txt"

  let assert Ok(Nil) =
    download.fetch_file_to_disk(
      url: "http://127.0.0.1:"
        <> int.to_string(redirect_port)
        <> "/files/id-1?alt=media",
      access_token: "at-1",
      destination: destination,
      timeout_ms: 5000,
    )
  // The redirected request reached the target without the Authorization
  // header (had it forwarded the bearer, the body would be "leaked-auth").
  assert simplifile.read(destination) == Ok("no-auth")
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
  // acknowledgeAbuse lets an abuse-flagged (but user-owned) file download
  // instead of failing every round.
  assert download.build_media_url("id-42")
    == "https://www.googleapis.com/drive/v3/files/id-42?alt=media&acknowledgeAbuse=true"
}

// Export MIME types contain a `/` (and `+` in some formats), so the query
// value must be percent-encoded.
pub fn the_export_url_carries_the_encoded_export_mime_test() {
  assert download.build_export_url(
      "id-9",
      "application/vnd.oasis.opendocument.text",
    )
    == "https://www.googleapis.com/drive/v3/files/id-9/export"
    <> "?mimeType=application%2Fvnd.oasis.opendocument.text"
}

// PENTEST — file_id is Drive-supplied metadata. Google assigns opaque ids
// today, but the builder must not depend on that: an id carrying `/`, `?` or
// `#` must be percent-encoded so it cannot inject query params or walk the
// path to a different endpoint on the API host.
pub fn a_crafted_file_id_cannot_break_out_of_the_url_test() {
  let evil = "id/../../tokeninfo?x=1"

  let media = download.build_media_url(evil)
  assert !string.contains(media, "id/../")
  assert string.contains(media, "id%2F..%2F..%2Ftokeninfo%3Fx%3D1")

  let export = download.build_export_url(evil, "text/plain")
  assert !string.contains(export, "id/../")
  assert string.contains(export, "id%2F..%2F..%2Ftokeninfo%3Fx%3D1/export")
}
