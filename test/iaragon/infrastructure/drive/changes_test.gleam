import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/uri
import iaragon/infrastructure/drive/changes.{
  ChangePage, Changed, ChangedFile, Done, NextPage, Removed,
}

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

// --- startPageToken -----------------------------------------------------------

pub fn fetching_the_start_page_token_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, "{\"startPageToken\":\"tok-1\"}")

  assert changes.fetch_start_page_token(send, access_token: "at-1")
    == Ok("tok-1")

  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.method == http.Get
  assert sent.host == "www.googleapis.com"
  assert sent.path == "/drive/v3/changes/startPageToken"
  assert request.get_header(sent, "authorization") == Ok("Bearer at-1")
}

// --- changes.list -------------------------------------------------------------

const a_middle_page = "{\"changes\":["
  <> "{\"fileId\":\"id-1\",\"removed\":false,\"file\":{\"id\":\"id-1\","
  <> "\"name\":\"report.txt\",\"mimeType\":\"text/plain\",\"parents\":[\"p-1\"],"
  <> "\"modifiedTime\":\"2026-07-01T10:00:00Z\",\"size\":\"42\","
  <> "\"md5Checksum\":\"aaa\",\"trashed\":false}},"
  <> "{\"fileId\":\"id-2\",\"removed\":true},"
  <> "{\"fileId\":\"id-3\",\"removed\":false,\"file\":{\"id\":\"id-3\","
  <> "\"name\":\"notes\",\"mimeType\":\"application/vnd.google-apps.document\","
  <> "\"parents\":[\"p-1\"],\"modifiedTime\":\"2026-07-02T09:00:00Z\","
  <> "\"trashed\":true}}"
  <> "],\"nextPageToken\":\"next-1\"}"

pub fn a_middle_page_parses_changes_and_next_token_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, a_middle_page)

  let expected_blob =
    ChangedFile(
      file_id: "id-1",
      name: "report.txt",
      mime_type: "text/plain",
      parent_id: Some("p-1"),
      modified_time: "2026-07-01T10:00:00Z",
      size: Some(42),
      md5: Some("aaa"),
      trashed: False,
    )
  let expected_native =
    ChangedFile(
      file_id: "id-3",
      name: "notes",
      mime_type: "application/vnd.google-apps.document",
      parent_id: Some("p-1"),
      modified_time: "2026-07-02T09:00:00Z",
      size: None,
      md5: None,
      trashed: True,
    )
  assert changes.fetch_changes_page(send, access_token: "at-1", page_token: "tok-1")
    == Ok(ChangePage(
      changes: [Changed(expected_blob), Removed("id-2"), Changed(expected_native)],
      outcome: NextPage("next-1"),
    ))

  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.path == "/drive/v3/changes"
  assert request.get_header(sent, "authorization") == Ok("Bearer at-1")
  let assert Some(query) = sent.query
  let assert Ok(params) = uri.parse_query(query)
  assert list.key_find(params, "pageToken") == Ok("tok-1")
  // Defaults are undocumented; the daemon must pin these explicitly.
  assert list.key_find(params, "includeRemoved") == Ok("true")
  assert list.key_find(params, "restrictToMyDrive") == Ok("true")
}

pub fn the_final_page_carries_the_new_start_token_test() {
  let inbox = process.new_subject()
  let send =
    respond_with(inbox, 200, "{\"changes\":[],\"newStartPageToken\":\"fresh-1\"}")
  assert changes.fetch_changes_page(send, access_token: "at-1", page_token: "tok-9")
    == Ok(ChangePage(changes: [], outcome: Done("fresh-1")))
}

pub fn a_quota_refusal_carries_status_and_body_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 403, "{\"error\":{\"errors\":[]}}")
  assert changes.fetch_changes_page(send, access_token: "at-1", page_token: "t")
    == Error(changes.RefusedByServer(403, "{\"error\":{\"errors\":[]}}"))
}

pub fn an_unparseable_body_is_reported_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, "<html>")
  assert changes.fetch_changes_page(send, access_token: "at-1", page_token: "t")
    == Error(changes.UnexpectedPayload("<html>"))
}
