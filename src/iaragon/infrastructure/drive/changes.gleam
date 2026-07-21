//// Client for the Drive v3 Changes API, the source of remote deltas:
//// GET /drive/v3/changes/startPageToken (token never expires) and
//// GET /drive/v3/changes?pageToken=… paginated by nextPageToken until the
//// final page carries newStartPageToken (which must be persisted).
////
//// `includeRemoved` and `restrictToMyDrive` are pinned explicitly because
//// their defaults are not documented. `removed=true` (no `file` object)
//// means permanent deletion or lost access; trashing arrives as an ordinary
//// change with `file.trashed=true`. Drive serialises int64 fields like
//// `size` as JSON strings.

import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The HTTP transport, injected so tests never touch the network.
pub type SendRequest =
  fn(Request(String)) -> Result(Response(String), String)

/// One change entry, already interpreted: either fresh metadata for a file,
/// or the fact that it is permanently gone (or out of reach).
pub type Change {
  Changed(file: ChangedFile)
  Removed(file_id: String)
}

/// Metadata as the Changes API reports it. There is no POSIX path here —
/// resolving paths out of parent ids is the (lossy) job of a later layer.
pub type ChangedFile {
  ChangedFile(
    file_id: String,
    name: String,
    mime_type: String,
    parent_id: Option(String),
    modified_time: String,
    size: Option(Int),
    md5: Option(String),
    trashed: Bool,
  )
}

pub type ChangePage {
  ChangePage(changes: List(Change), outcome: PageOutcome)
}

pub type PageOutcome {
  /// More pages to fetch with this token.
  NextPage(page_token: String)
  /// End of the list; persist this token for the next polling cycle.
  Done(new_start_page_token: String)
}

pub type DriveError {
  TransportFailed(reason: String)
  RefusedByServer(status: Int, body: String)
  UnexpectedPayload(body: String)
}

const drive_host = "www.googleapis.com"

pub fn fetch_start_page_token(
  send: SendRequest,
  access_token access_token: String,
) -> Result(String, DriveError) {
  let request = build_get(access_token, "/drive/v3/changes/startPageToken", [])
  use body <- result.try(fetch_ok_body(send, request))
  let decoder = {
    use token <- decode.field("startPageToken", decode.string)
    decode.success(token)
  }
  json.parse(from: body, using: decoder)
  |> result.replace_error(UnexpectedPayload(body))
}

pub fn fetch_changes_page(
  send: SendRequest,
  access_token access_token: String,
  page_token page_token: String,
) -> Result(ChangePage, DriveError) {
  let request =
    build_get(access_token, "/drive/v3/changes", [
      #("pageToken", page_token),
      #("includeRemoved", "true"),
      #("restrictToMyDrive", "true"),
      #(
        "fields",
        "newStartPageToken,nextPageToken,changes(fileId,removed,"
          <> "file(id,name,mimeType,parents,modifiedTime,size,md5Checksum,trashed))",
      ),
    ])
  use body <- result.try(fetch_ok_body(send, request))
  json.parse(from: body, using: change_page_decoder())
  |> result.replace_error(UnexpectedPayload(body))
}

/// Walk every page from `page_token` to the end, accumulating changes, and
/// return them with the `newStartPageToken` to persist for the next cycle.
/// Fails fast on the first refusal — retry/backoff is the caller's policy.
pub fn fetch_all_changes(
  send: SendRequest,
  access_token access_token: String,
  page_token page_token: String,
) -> Result(#(List(Change), String), DriveError) {
  fetch_remaining_changes(send, access_token, page_token, [])
}

fn fetch_remaining_changes(
  send: SendRequest,
  access_token: String,
  page_token: String,
  seen: List(Change),
) -> Result(#(List(Change), String), DriveError) {
  use page <- result.try(fetch_changes_page(send, access_token, page_token))
  let seen = list.append(seen, page.changes)
  case page.outcome {
    NextPage(next) -> fetch_remaining_changes(send, access_token, next, seen)
    Done(fresh) -> Ok(#(seen, fresh))
  }
}

fn build_get(
  access_token: String,
  path: String,
  query: List(#(String, String)),
) -> Request(String) {
  let request =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_scheme(http.Https)
    |> request.set_host(drive_host)
    |> request.set_path(path)
    |> request.set_header("authorization", "Bearer " <> access_token)
  case query {
    [] -> request
    query -> request.set_query(request, query)
  }
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

fn change_page_decoder() -> decode.Decoder(ChangePage) {
  use changes <- decode.field("changes", decode.list(change_decoder()))
  use next <- decode.optional_field(
    "nextPageToken",
    None,
    decode.optional(decode.string),
  )
  use fresh <- decode.optional_field(
    "newStartPageToken",
    None,
    decode.optional(decode.string),
  )
  case next, fresh {
    Some(token), _ -> decode.success(ChangePage(changes, NextPage(token)))
    None, Some(token) -> decode.success(ChangePage(changes, Done(token)))
    None, None ->
      decode.failure(ChangePage([], Done("")), "page with a continuation token")
  }
}

fn change_decoder() -> decode.Decoder(Change) {
  use file_id <- decode.field("fileId", decode.string)
  use removed <- decode.field("removed", decode.bool)
  case removed {
    True -> decode.success(Removed(file_id))
    False -> {
      use file <- decode.field("file", changed_file_decoder())
      decode.success(Changed(file))
    }
  }
}

fn changed_file_decoder() -> decode.Decoder(ChangedFile) {
  use file_id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use mime_type <- decode.field("mimeType", decode.string)
  use parents <- decode.optional_field(
    "parents",
    [],
    decode.list(decode.string),
  )
  use modified_time <- decode.field("modifiedTime", decode.string)
  use size_text <- decode.optional_field(
    "size",
    None,
    decode.optional(decode.string),
  )
  use md5 <- decode.optional_field(
    "md5Checksum",
    None,
    decode.optional(decode.string),
  )
  use trashed <- decode.optional_field("trashed", False, decode.bool)
  decode.success(ChangedFile(
    file_id:,
    name:,
    mime_type:,
    parent_id: list.first(parents) |> option.from_result,
    modified_time:,
    size: size_text
      |> option.then(fn(text) { option.from_result(int.parse(text)) }),
    md5:,
    trashed:,
  ))
}
