//// Resumable upload, the mandatory path for large files: POST (create) or
//// PATCH (update) initiates a session whose URI arrives in the Location
//// header; bytes go up in PUT chunks with Content-Range, answered with 308
//// Resume Incomplete until the final chunk returns the file metadata.
//// Chunks must be multiples of 256 KB except the last (the composition uses
//// 8 MiB); the session URI is valid for about a week — long enough that a
//// failed transfer is simply restarted by the pool's retry, not resumed.

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/result
import iaragon/infrastructure/drive/changes.{
  type ChangedFile, type DriveError, RefusedByServer, TransportFailed,
  UnexpectedPayload,
}
import iaragon/infrastructure/fs/chunked_read.{EndOfFile, NextChunk}

/// Binary-body transport, injected so tests never touch the network.
pub type SendBits =
  fn(Request(BitArray)) -> Result(Response(String), String)

pub type UploadTarget {
  CreateFile(name: String, parent_id: String)
  UpdateFile(file_id: String)
}

const upload_host = "www.googleapis.com"

const fields_projection = "id,name,mimeType,parents,modifiedTime,size,"
  <> "md5Checksum,trashed"

pub fn upload_file(
  send: SendBits,
  access_token access_token: String,
  target target: UploadTarget,
  source_path source_path: String,
  total_size total_size: Int,
  chunk_size chunk_size: Int,
) -> Result(ChangedFile, DriveError) {
  use session_url <- result.try(initiate_session(send, access_token, target))
  use handle <- result.try(
    chunked_read.open_read(source_path) |> result.map_error(TransportFailed),
  )
  let outcome =
    send_chunks(send, session_url, handle, chunk_size, 0, total_size)
  let _ = chunked_read.close(handle)
  outcome
}

fn initiate_session(
  send: SendBits,
  access_token: String,
  target: UploadTarget,
) -> Result(String, DriveError) {
  let #(method, path, metadata) = case target {
    CreateFile(name, parent_id) -> #(
      http.Post,
      "/upload/drive/v3/files",
      json.object([
        #("name", json.string(name)),
        #("parents", json.array([parent_id], json.string)),
      ]),
    )
    UpdateFile(file_id) -> #(
      http.Patch,
      "/upload/drive/v3/files/" <> file_id,
      json.object([]),
    )
  }
  let request =
    request.new()
    |> request.set_method(method)
    |> request.set_scheme(http.Https)
    |> request.set_host(upload_host)
    |> request.set_path(path)
    |> request.set_query([
      #("uploadType", "resumable"),
      #("fields", fields_projection),
    ])
    |> request.set_header("authorization", "Bearer " <> access_token)
    |> request.set_header("content-type", "application/json; charset=UTF-8")
    |> request.set_body(bit_array.from_string(json.to_string(metadata)))

  use response <- result.try(send(request) |> result.map_error(TransportFailed))
  case response.status {
    200 ->
      response.get_header(response, "location")
      |> result.replace_error(UnexpectedPayload(
        "no session URI in the initiate response",
      ))
    status -> Error(RefusedByServer(status, response.body))
  }
}

fn send_chunks(
  send: SendBits,
  session_url: String,
  handle: chunked_read.FileHandle,
  chunk_size: Int,
  offset: Int,
  total_size: Int,
) -> Result(ChangedFile, DriveError) {
  use chunk <- result.try(
    chunked_read.read_chunk(handle, chunk_size)
    |> result.map_error(TransportFailed),
  )
  case chunk {
    EndOfFile ->
      Error(UnexpectedPayload(
        "the file ended at byte "
        <> int.to_string(offset)
        <> " but "
        <> int.to_string(total_size)
        <> " were promised",
      ))
    NextChunk(bytes) -> {
      let length = bit_array.byte_size(bytes)
      let content_range =
        "bytes "
        <> int.to_string(offset)
        <> "-"
        <> int.to_string(offset + length - 1)
        <> "/"
        <> int.to_string(total_size)
      use put <- result.try(
        request.to(session_url)
        |> result.replace_error(UnexpectedPayload(
          "unparseable session URI: " <> session_url,
        )),
      )
      let put =
        put
        |> request.set_method(http.Put)
        |> request.set_header("content-range", content_range)
        |> request.set_body(bytes)

      use response <- result.try(send(put) |> result.map_error(TransportFailed))
      case response.status {
        308 ->
          send_chunks(
            send,
            session_url,
            handle,
            chunk_size,
            offset + length,
            total_size,
          )
        200 | 201 ->
          json.parse(from: response.body, using: changes.changed_file_decoder())
          |> result.replace_error(UnexpectedPayload(response.body))
        status -> Error(RefusedByServer(status, response.body))
      }
    }
  }
}
