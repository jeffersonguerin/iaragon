//// Conflicted-copy naming, the chosen edit-edit resolution policy: the
//// local version moves aside under a dated marker (and syncs up as a new
//// file), while the remote version takes the original path. Pure.

import gleam/list
import gleam/string
import iaragon/domain/paths

pub fn build_conflicted_copy_path(path: String, date date: String) -> String {
  let #(directory, name) = split_directory(path)
  let #(stem, extension) = paths.split_extension(name)
  let marked = stem <> " (conflicted copy " <> date <> ")"
  let marked = case extension {
    "" -> marked
    extension -> marked <> "." <> extension
  }
  case directory {
    "" -> marked
    directory -> directory <> "/" <> marked
  }
}

fn split_directory(path: String) -> #(String, String) {
  let segments = string.split(path, "/")
  case list.reverse(segments) {
    [name, ..reversed_directory] -> #(
      string.join(list.reverse(reversed_directory), "/"),
      name,
    )
    [] -> #("", path)
  }
}
