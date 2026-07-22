//// Downloads Drive blob content (`files/{id}?alt=media`) streaming straight
//// to disk via a thin httpc FFI — never holding the body in memory. Parent
//// directories are created on demand; a refused response writes nothing.

import filepath
import gleam/result
import gleam/uri
import simplifile

pub type DownloadError {
  TransportFailed(reason: String)
  RefusedByServer(status: Int)
}

pub fn build_media_url(file_id: String) -> String {
  "https://www.googleapis.com/drive/v3/files/" <> file_id <> "?alt=media"
}

/// Native-doc export (`files/{id}/export`). Same streaming download as
/// `alt=media` behind it — only the URL differs. Export MIMEs contain `/`,
/// so the query value is percent-encoded.
pub fn build_export_url(file_id: String, export_mime: String) -> String {
  "https://www.googleapis.com/drive/v3/files/"
  <> file_id
  <> "/export?mimeType="
  <> uri.percent_encode(export_mime)
}

pub fn fetch_file_to_disk(
  url url: String,
  access_token access_token: String,
  destination destination: String,
  timeout_ms timeout_ms: Int,
) -> Result(Nil, DownloadError) {
  use Nil <- result.try(
    simplifile.create_directory_all(filepath.directory_name(destination))
    |> result.map_error(fn(error) {
      TransportFailed(
        "cannot create directory: " <> simplifile.describe_error(error),
      )
    }),
  )
  // httpc's {stream, path} APPENDS to an existing file, so bytes go to a
  // partial file that atomically replaces the destination only on success —
  // a crashed download never leaves a half-written mirror file behind.
  let partial = destination <> ".iaragon-partial"
  let _ = simplifile.delete(partial)
  case download_to_file(url, "Bearer " <> access_token, partial, timeout_ms) {
    Ok(Nil) ->
      simplifile.rename(at: partial, to: destination)
      |> result.map_error(fn(error) {
        TransportFailed(
          "cannot move download in place: " <> simplifile.describe_error(error),
        )
      })
    Error(error) -> {
      let _ = simplifile.delete(partial)
      Error(error)
    }
  }
}

@external(erlang, "iaragon_download_ffi", "download_to_file")
fn download_to_file(
  url: String,
  authorization: String,
  destination: String,
  timeout_ms: Int,
) -> Result(Nil, DownloadError)
