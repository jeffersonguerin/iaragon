import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/uri
import iaragon/infrastructure/drive/changes.{ChangedFile}
import iaragon/infrastructure/drive/listing

// The first mirror cannot come from the Changes API: files.list provides the
// full snapshot (paginated), and files/root provides the real root id that
// anchors path resolution (parents always carry real ids, never the alias).

fn respond_with(
  inbox: process.Subject(request.Request(String)),
  status: Int,
  body: String,
) -> changes.SendRequest {
  fn(request) {
    process.send(inbox, request)
    Ok(response.Response(status: status, headers: [], body: body))
  }
}

pub fn fetching_the_root_id_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, "{\"id\":\"root-id-1\"}")

  assert listing.fetch_root_id(send, access_token: "at-1") == Ok("root-id-1")

  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.host == "www.googleapis.com"
  assert sent.path == "/drive/v3/files/root"
  assert request.get_header(sent, "authorization") == Ok("Bearer at-1")
  let assert Some(query) = sent.query
  let assert Ok(params) = uri.parse_query(query)
  assert list.key_find(params, "fields") == Ok("id")
}

fn a_files_page(file_id: String, continuation: String) -> String {
  "{\"files\":[{\"id\":\""
  <> file_id
  <> "\",\"name\":\"a.txt\",\"mimeType\":\"text/plain\",\"parents\":[\"p-1\"],"
  <> "\"modifiedTime\":\"2026-07-01T10:00:00Z\",\"size\":\"42\","
  <> "\"md5Checksum\":\"aaa\",\"trashed\":false}]"
  <> continuation
  <> "}"
}

pub fn listing_walks_every_page_test() {
  let inbox = process.new_subject()
  let send = fn(sent: request.Request(String)) {
    process.send(inbox, sent)
    let assert Some(query) = sent.query
    let assert Ok(params) = uri.parse_query(query)
    let body = case list.key_find(params, "pageToken") {
      Error(Nil) -> a_files_page("id-1", ",\"nextPageToken\":\"page-2\"")
      Ok("page-2") -> a_files_page("id-2", "")
      other -> panic as { "unexpected page token: " <> string.inspect(other) }
    }
    Ok(response.Response(status: 200, headers: [], body: body))
  }

  let assert Ok([first, second]) =
    listing.fetch_full_listing(send, access_token: "at-1")
  let assert ChangedFile(file_id: "id-1", md5: Some("aaa"), ..) = first
  let assert ChangedFile(file_id: "id-2", ..) = second

  // The listing must exclude trash and stay inside My Drive, explicitly.
  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.path == "/drive/v3/files"
  let assert Some(query) = sent.query
  let assert Ok(params) = uri.parse_query(query)
  assert list.key_find(params, "q") == Ok("trashed = false")
  assert list.key_find(params, "corpora") == Ok("user")
  assert list.key_find(params, "spaces") == Ok("drive")
  assert list.key_find(params, "pageSize") == Ok("1000")
  // The projection must ask for everything the parser reads.
  let assert Ok(fields) = list.key_find(params, "fields")
  assert string.contains(fields, "shortcutDetails(targetId)")
}

// PENTEST — a listing that always returns a nextPageToken must be bounded
// rather than looping / growing memory forever.
pub fn a_never_ending_listing_is_bounded_test() {
  let send = fn(_sent: request.Request(String)) {
    Ok(response.Response(
      status: 200,
      headers: [],
      body: a_files_page("id-x", ",\"nextPageToken\":\"more\""),
    ))
  }
  let assert Error(changes.UnexpectedPayload(_)) =
    listing.fetch_full_listing(send, access_token: "at-1")
}

pub fn a_refused_listing_reports_status_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 403, "quota")
  assert listing.fetch_full_listing(send, access_token: "at-1")
    == Error(changes.RefusedByServer(403, "quota"))
}
