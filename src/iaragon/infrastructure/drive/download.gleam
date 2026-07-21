//// Downloads Drive blob content (`files/{id}?alt=media`) streaming straight
//// to disk via a thin httpc FFI — never holding the body in memory. Parent
//// directories are created on demand; a refused response writes nothing.

import filepath
import gleam/result
import simplifile

pub type DownloadError {
  TransportFailed(reason: String)
  RefusedByServer(status: Int)
}

pub fn build_media_url(file_id: String) -> String {
  "https://www.googleapis.com/drive/v3/files/" <> file_id <> "?alt=media"
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
      TransportFailed("cannot create directory: " <> simplifile.describe_error(error))
    }),
  )
  download_to_file(url, "Bearer " <> access_token, destination, timeout_ms)
}

@external(erlang, "iaragon_download_ffi", "download_to_file")
fn download_to_file(
  url: String,
  authorization: String,
  destination: String,
  timeout_ms: Int,
) -> Result(Nil, DownloadError)
