import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/string
import gleam/uri
import iaragon/infrastructure/drive/changes.{ChangedFile}
import iaragon/infrastructure/drive/mutate

// Metadata mutations: folder creation (files.create, metadata only) and
// trashing (files.update trashed=true). A locally deleted file is TRASHED
// remotely, never permanently deleted — recoverable by design.

fn respond_with(
  inbox: process.Subject(request.Request(String)),
  status: Int,
  body: String,
) -> changes.SendRequest {
  fn(sent) {
    process.send(inbox, sent)
    Ok(response.Response(status: status, headers: [], body: body))
  }
}

const a_folder_payload = "{\"id\":\"id-f\",\"name\":\"docs\","
  <> "\"mimeType\":\"application/vnd.google-apps.folder\",\"parents\":[\"p-1\"],"
  <> "\"modifiedTime\":\"2026-07-22T10:00:00Z\",\"trashed\":false}"

pub fn creating_a_folder_posts_metadata_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, a_folder_payload)

  let assert Ok(created) =
    mutate.create_folder(
      send,
      access_token: "at-1",
      name: "docs",
      parent_id: "p-1",
    )
  let assert ChangedFile(
    file_id: "id-f",
    mime_type: "application/vnd.google-apps.folder",
    ..,
  ) = created

  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.method == http.Post
  assert sent.host == "www.googleapis.com"
  assert sent.path == "/drive/v3/files"
  assert request.get_header(sent, "authorization") == Ok("Bearer at-1")
  assert string.contains(sent.body, "\"name\":\"docs\"")
  assert string.contains(sent.body, "\"parents\":[\"p-1\"]")
  assert string.contains(
    sent.body,
    "\"mimeType\":\"application/vnd.google-apps.folder\"",
  )
}

pub fn trashing_patches_the_trashed_flag_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, "{\"id\":\"id-1\",\"trashed\":true}")

  assert mutate.trash_file(send, access_token: "at-1", file_id: "id-1")
    == Ok(Nil)

  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.method == http.Patch
  assert sent.path == "/drive/v3/files/id-1"
  assert sent.body == "{\"trashed\":true}"
}

const a_renamed_payload = "{\"id\":\"id-1\",\"name\":\"renamed.txt\","
  <> "\"mimeType\":\"text/plain\",\"parents\":[\"id-new-parent\"],"
  <> "\"modifiedTime\":\"2026-07-22T10:00:00Z\",\"size\":\"42\","
  <> "\"md5Checksum\":\"aaa\",\"trashed\":false}"

pub fn renaming_patches_name_and_swaps_parents_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 200, a_renamed_payload)

  let assert Ok(renamed) =
    mutate.rename_file(
      send,
      access_token: "at-1",
      file_id: "id-1",
      new_name: "renamed.txt",
      add_parent_id: "id-new-parent",
      remove_parent_id: "id-old-parent",
    )
  let assert ChangedFile(file_id: "id-1", name: "renamed.txt", ..) = renamed

  let assert Ok(sent) = process.receive(inbox, 100)
  assert sent.method == http.Patch
  assert sent.path == "/drive/v3/files/id-1"
  assert string.contains(sent.body, "\"name\":\"renamed.txt\"")
  let assert option.Some(query) = sent.query
  let assert Ok(params) = uri.parse_query(query)
  assert list.key_find(params, "addParents") == Ok("id-new-parent")
  assert list.key_find(params, "removeParents") == Ok("id-old-parent")
}

pub fn a_refused_mutation_reports_status_test() {
  let inbox = process.new_subject()
  let send = respond_with(inbox, 403, "quota")
  assert mutate.trash_file(send, access_token: "at-1", file_id: "id-1")
    == Error(changes.RefusedByServer(403, "quota"))
  assert mutate.create_folder(
      send,
      access_token: "at-1",
      name: "x",
      parent_id: "p",
    )
    == Error(changes.RefusedByServer(403, "quota"))
}
