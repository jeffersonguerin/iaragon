import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri
import iaragon/infrastructure/drive/changes.{ChangedFile}
import iaragon/infrastructure/drive/upload.{CreateFile, UpdateFile}
import simplifile

// Resumable upload, per the official docs: POST (or PATCH, for updates)
// initiates a session whose URI comes back in the Location header; the bytes
// then go up in PUTs with Content-Range, answered with 308 Resume Incomplete
// until the final chunk returns the file metadata.

const scratch_dir = "build/test-scratch/upload"

const session_url = "https://upload.googleapis.com/session/abc?upload_id=xyz"

const a_file_payload = "{\"id\":\"id-up\",\"name\":\"report.txt\","
  <> "\"mimeType\":\"text/plain\",\"parents\":[\"p-1\"],"
  <> "\"modifiedTime\":\"2026-07-22T10:00:00Z\",\"size\":\"6\","
  <> "\"md5Checksum\":\"m-up\",\"trashed\":false}"

fn a_source_file(name: String, contents: String) -> String {
  let path = scratch_dir <> "/" <> name
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir)
  let assert Ok(Nil) = simplifile.write(to: path, contents: contents)
  path
}

/// Answers the initiate with the session URI, intermediate chunks with 308,
/// and the final chunk (Content-Range reaching the total) with metadata.
fn a_session_send(
  inbox: process.Subject(request.Request(BitArray)),
) -> upload.SendBits {
  fn(sent: request.Request(BitArray)) {
    process.send(inbox, sent)
    case request.get_header(sent, "content-range") {
      Error(Nil) ->
        Ok(response.Response(
          status: 200,
          headers: [#("location", session_url)],
          body: "",
        ))
      Ok(content_range) ->
        case string.ends_with(content_range, "/6") {
          True ->
            case string.contains(content_range, "-5/6") {
              True ->
                Ok(response.Response(status: 200, headers: [], body: a_file_payload))
              False ->
                Ok(response.Response(status: 308, headers: [], body: ""))
            }
          False -> panic as { "unexpected content-range: " <> content_range }
        }
    }
  }
}

pub fn creating_a_file_uploads_all_chunks_test() {
  let inbox = process.new_subject()
  let source = a_source_file("create.txt", "abcdef")

  let assert Ok(uploaded) =
    upload.upload_file(
      a_session_send(inbox),
      access_token: "at-1",
      target: CreateFile(name: "report.txt", parent_id: "p-1"),
      source_path: source,
      total_size: 6,
      chunk_size: 4,
    )
  let assert ChangedFile(file_id: "id-up", md5: Some("m-up"), ..) = uploaded

  // Initiate: resumable POST with metadata and the exact fields projection.
  let assert Ok(initiate) = process.receive(inbox, 100)
  assert initiate.method == http.Post
  assert initiate.host == "www.googleapis.com"
  assert initiate.path == "/upload/drive/v3/files"
  let assert Some(query) = initiate.query
  let assert Ok(params) = uri.parse_query(query)
  assert list.key_find(params, "uploadType") == Ok("resumable")
  assert request.get_header(initiate, "authorization") == Ok("Bearer at-1")
  assert request.get_header(initiate, "content-type")
    == Ok("application/json; charset=UTF-8")
  let assert Ok(metadata) = bit_array.to_string(initiate.body)
  assert string.contains(metadata, "\"name\":\"report.txt\"")
  assert string.contains(metadata, "\"parents\":[\"p-1\"]")

  // Chunks: PUTs against the session URI with Content-Range.
  let assert Ok(first) = process.receive(inbox, 100)
  assert first.method == http.Put
  assert first.host == "upload.googleapis.com"
  assert request.get_header(first, "content-range") == Ok("bytes 0-3/6")
  assert first.body == <<"abcd":utf8>>

  let assert Ok(second) = process.receive(inbox, 100)
  assert request.get_header(second, "content-range") == Ok("bytes 4-5/6")
  assert second.body == <<"ef":utf8>>
}

pub fn updating_targets_the_existing_file_id_test() {
  let inbox = process.new_subject()
  let source = a_source_file("update.txt", "abcdef")

  let assert Ok(_uploaded) =
    upload.upload_file(
      a_session_send(inbox),
      access_token: "at-1",
      target: UpdateFile(file_id: "id-9"),
      source_path: source,
      total_size: 6,
      chunk_size: 6,
    )

  let assert Ok(initiate) = process.receive(inbox, 100)
  assert initiate.method == http.Patch
  assert initiate.path == "/upload/drive/v3/files/id-9"
}

pub fn a_refused_initiate_reports_the_status_test() {
  let send = fn(_sent) {
    Ok(response.Response(status: 403, headers: [], body: "quota"))
  }
  let source = a_source_file("refused.txt", "abcdef")
  assert upload.upload_file(
      send,
      access_token: "at-1",
      target: CreateFile(name: "x", parent_id: "p-1"),
      source_path: source,
      total_size: 6,
      chunk_size: 6,
    )
    == Error(changes.RefusedByServer(403, "quota"))
}

pub fn an_initiate_without_a_session_url_is_unexpected_test() {
  let send = fn(_sent) {
    Ok(response.Response(status: 200, headers: [], body: ""))
  }
  let source = a_source_file("no-session.txt", "abcdef")
  let assert Error(changes.UnexpectedPayload(_)) =
    upload.upload_file(
      send,
      access_token: "at-1",
      target: CreateFile(name: "x", parent_id: "p-1"),
      source_path: source,
      total_size: 6,
      chunk_size: 6,
    )
}

pub fn a_mid_upload_refusal_reports_the_status_test() {
  let inbox = process.new_subject()
  let send = fn(sent: request.Request(BitArray)) {
    process.send(inbox, sent)
    case request.get_header(sent, "content-range") {
      Error(Nil) ->
        Ok(response.Response(
          status: 200,
          headers: [#("location", session_url)],
          body: "",
        ))
      Ok(_) -> Ok(response.Response(status: 500, headers: [], body: "boom"))
    }
  }
  let source = a_source_file("mid-fail.txt", "abcdef")
  assert upload.upload_file(
      send,
      access_token: "at-1",
      target: CreateFile(name: "x", parent_id: "p-1"),
      source_path: source,
      total_size: 6,
      chunk_size: 6,
    )
    == Error(changes.RefusedByServer(500, "boom"))
}
