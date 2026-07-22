//// The initial mirror snapshot: files.list walked to the end, plus the real
//// id of the My Drive root (files/root) — parents in listings and changes
//// always carry real ids, so path resolution needs it as the anchor. After
//// this snapshot, the Changes API keeps the mirror fresh.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import iaragon/infrastructure/drive/changes.{
  type ChangedFile, type DriveError, type SendRequest, RefusedByServer,
  TransportFailed, UnexpectedPayload,
}

const drive_host = "www.googleapis.com"

pub fn fetch_root_id(
  send: SendRequest,
  access_token access_token: String,
) -> Result(String, DriveError) {
  let request =
    build_get(access_token, "/drive/v3/files/root", [#("fields", "id")])
  use body <- result.try(fetch_ok_body(send, request))
  let decoder = {
    use id <- decode.field("id", decode.string)
    decode.success(id)
  }
  json.parse(from: body, using: decoder)
  |> result.replace_error(UnexpectedPayload(body))
}

/// Walk every files.list page. Trash is excluded and the corpus is pinned to
/// My Drive, matching the restrictToMyDrive polling that follows.
pub fn fetch_full_listing(
  send: SendRequest,
  access_token access_token: String,
) -> Result(List(ChangedFile), DriveError) {
  fetch_remaining_files(send, access_token, None, [])
}

fn fetch_remaining_files(
  send: SendRequest,
  access_token: String,
  page_token: option.Option(String),
  seen: List(ChangedFile),
) -> Result(List(ChangedFile), DriveError) {
  let query = [
    #("q", "trashed = false"),
    #("corpora", "user"),
    #("spaces", "drive"),
    #("pageSize", "1000"),
    #(
      "fields",
      "nextPageToken,files(id,name,mimeType,parents,modifiedTime,size,"
        <> "md5Checksum,trashed,shortcutDetails(targetId))",
    ),
  ]
  let query = case page_token {
    Some(token) -> [#("pageToken", token), ..query]
    None -> query
  }
  let request = build_get(access_token, "/drive/v3/files", query)
  use body <- result.try(fetch_ok_body(send, request))
  use page <- result.try(
    json.parse(from: body, using: files_page_decoder())
    |> result.replace_error(UnexpectedPayload(body)),
  )
  let #(files, next) = page
  let seen = list.append(seen, files)
  case next {
    Some(token) -> fetch_remaining_files(send, access_token, Some(token), seen)
    None -> Ok(seen)
  }
}

fn files_page_decoder() -> decode.Decoder(
  #(List(ChangedFile), option.Option(String)),
) {
  use files <- decode.field(
    "files",
    decode.list(changes.changed_file_decoder()),
  )
  use next <- decode.optional_field(
    "nextPageToken",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(files, next))
}

fn build_get(
  access_token: String,
  path: String,
  query: List(#(String, String)),
) -> Request(String) {
  request.new()
  |> request.set_method(http.Get)
  |> request.set_scheme(http.Https)
  |> request.set_host(drive_host)
  |> request.set_path(path)
  |> request.set_header("authorization", "Bearer " <> access_token)
  |> request.set_query(query)
}

fn fetch_ok_body(
  send: SendRequest,
  request: Request(String),
) -> Result(String, DriveError) {
  use response <- result.try(send(request) |> result.map_error(TransportFailed))
  case response.status {
    200 -> Ok(response.body)
    status -> Error(RefusedByServer(status, response.body))
  }
}
