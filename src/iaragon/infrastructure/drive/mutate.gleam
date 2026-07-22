//// Metadata mutations on Drive: folder creation (files.create with the
//// folder mimeType, no media) and trashing (files.update trashed=true).
//// A locally deleted file is TRASHED remotely, never permanently deleted:
//// the trash is recoverable, a hard delete is not.

import gleam/http
import gleam/http/request.{type Request}
import gleam/json
import gleam/result
import iaragon/infrastructure/drive/changes.{
  type ChangedFile, type DriveError, type SendRequest, RefusedByServer,
  TransportFailed, UnexpectedPayload,
}

const drive_host = "www.googleapis.com"

const fields_projection = "id,name,mimeType,parents,modifiedTime,size,"
  <> "md5Checksum,trashed"

pub fn create_folder(
  send: SendRequest,
  access_token access_token: String,
  name name: String,
  parent_id parent_id: String,
) -> Result(ChangedFile, DriveError) {
  let metadata =
    json.object([
      #("name", json.string(name)),
      #("mimeType", json.string("application/vnd.google-apps.folder")),
      #("parents", json.array([parent_id], json.string)),
    ])
  let request =
    build_json_request(access_token, http.Post, "/drive/v3/files", metadata)
    |> request.set_query([#("fields", fields_projection)])

  use body <- result.try(fetch_ok_body(send, request))
  json.parse(from: body, using: changes.changed_file_decoder())
  |> result.replace_error(UnexpectedPayload(body))
}

/// Rename and/or move a file without touching its bytes: files.update with
/// the new name in the body and the parent swap in the query (single-parent
/// world: one added, one removed).
pub fn rename_file(
  send: SendRequest,
  access_token access_token: String,
  file_id file_id: String,
  new_name new_name: String,
  add_parent_id add_parent_id: String,
  remove_parent_id remove_parent_id: String,
) -> Result(ChangedFile, DriveError) {
  let request =
    build_json_request(
      access_token,
      http.Patch,
      "/drive/v3/files/" <> file_id,
      json.object([#("name", json.string(new_name))]),
    )
    |> request.set_query([
      #("addParents", add_parent_id),
      #("removeParents", remove_parent_id),
      #("fields", fields_projection),
    ])

  use body <- result.try(fetch_ok_body(send, request))
  json.parse(from: body, using: changes.changed_file_decoder())
  |> result.replace_error(UnexpectedPayload(body))
}

pub fn trash_file(
  send: SendRequest,
  access_token access_token: String,
  file_id file_id: String,
) -> Result(Nil, DriveError) {
  let request =
    build_json_request(
      access_token,
      http.Patch,
      "/drive/v3/files/" <> file_id,
      json.object([#("trashed", json.bool(True))]),
    )
  use _body <- result.try(fetch_ok_body(send, request))
  Ok(Nil)
}

fn build_json_request(
  access_token: String,
  method: http.Method,
  path: String,
  metadata: json.Json,
) -> Request(String) {
  request.new()
  |> request.set_method(method)
  |> request.set_scheme(http.Https)
  |> request.set_host(drive_host)
  |> request.set_path(path)
  |> request.set_header("authorization", "Bearer " <> access_token)
  |> request.set_header("content-type", "application/json; charset=UTF-8")
  |> request.set_body(json.to_string(metadata))
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
