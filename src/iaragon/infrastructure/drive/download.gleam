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

/// Reserved per-folder control directory for in-flight partial downloads;
/// the local scan skips it. Must match `local_scan`'s own constant.
const partial_dir_name = ".iaragon-partial"

pub fn build_media_url(file_id: String) -> String {
  "https://www.googleapis.com/drive/v3/files/"
  <> uri.percent_encode(file_id)
  <> "?alt=media"
}

/// Native-doc export (`files/{id}/export`). Same streaming download as
/// `alt=media` behind it — only the URL differs. Both the id and the export
/// MIME are percent-encoded: MIMEs contain `/`, and the id is untrusted
/// metadata that must not be able to inject query params or walk the path.
pub fn build_export_url(file_id: String, export_mime: String) -> String {
  "https://www.googleapis.com/drive/v3/files/"
  <> uri.percent_encode(file_id)
  <> "/export?mimeType="
  <> uri.percent_encode(export_mime)
}

pub fn fetch_file_to_disk(
  url url: String,
  access_token access_token: String,
  destination destination: String,
  timeout_ms timeout_ms: Int,
) -> Result(Nil, DownloadError) {
  let directory = filepath.directory_name(destination)
  // Partials live in a reserved control dir INSIDE the destination's folder:
  // the scan skips `.iaragon-partial/` wholesale, and a rename within the
  // same folder is atomic (same filesystem). Keeping the original basename
  // avoids the length blow-up a flattened name would cause for deep paths.
  let partial_dir = directory <> "/" <> partial_dir_name
  use Nil <- result.try(
    simplifile.create_directory_all(partial_dir)
    |> result.map_error(fn(error) {
      TransportFailed(
        "cannot create directory: " <> simplifile.describe_error(error),
      )
    }),
  )
  // httpc's {stream, path} APPENDS to an existing file, so bytes go to a
  // partial file that atomically replaces the destination only on success —
  // a crashed download never leaves a half-written mirror file behind.
  let partial = partial_dir <> "/" <> filepath.base_name(destination)
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
