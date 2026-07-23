//// The mirror's local safety net. A mirror copy deleted because the remote
//// was trashed is MOVED into a reserved `.iaragon-trash/` directory inside
//// the mirror root — never unlinked. Every mature sync tool keeps some
//// local recovery path (Syncthing's .stversions, Dropbox's .dropbox.cache,
//// rclone's --backup-dir); ours preserves the file's relative path, adds a
//// numeric variant when the same path is trashed again, and relies on the
//// scan skipping the directory by LOCATION (like `.iaragon-partial/`).
////
//// Living inside the mirror root guarantees the same filesystem, so the
//// move is an atomic rename. Retention is applied by `sweep`, called once
//// at daemon boot — never from the sync path.

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import iaragon/domain/paths
import simplifile

pub const trash_dir_name = ".iaragon-trash"

pub fn move_to_trash(
  root_dir: String,
  relative_path: String,
) -> Result(Nil, String) {
  let source = root_dir <> "/" <> relative_path
  let destination = root_dir <> "/" <> trash_dir_name <> "/" <> relative_path
  use Nil <- result.try(
    simplifile.create_directory_all(parent_of(destination))
    |> result.map_error(simplifile.describe_error),
  )
  simplifile.rename(at: source, to: free_variant_of(destination, 2))
  |> result.map_error(simplifile.describe_error)
}

/// Remove trash entries older than the retention. Best-effort by design:
/// the trash is a convenience net, and a sweep failure must never block the
/// daemon's boot. Empty directories left behind are pruned opportunistically.
pub fn sweep(
  root_dir: String,
  now_unix now_unix: Int,
  retention_seconds retention_seconds: Int,
) -> Nil {
  let trash_root = root_dir <> "/" <> trash_dir_name
  case simplifile.is_directory(trash_root) {
    Ok(True) -> sweep_directory(trash_root, now_unix - retention_seconds)
    _ -> Nil
  }
}

fn sweep_directory(directory: String, cutoff_unix: Int) -> Nil {
  case simplifile.read_directory(directory) {
    Error(_) -> Nil
    Ok(entries) -> {
      list.each(entries, fn(entry) {
        let path = directory <> "/" <> entry
        case simplifile.is_directory(path) {
          Ok(True) -> sweep_directory(path, cutoff_unix)
          _ ->
            case simplifile.file_info(path) {
              Ok(info) if info.mtime_seconds < cutoff_unix -> {
                let _ = simplifile.delete_file(path)
                Nil
              }
              _ -> Nil
            }
        }
      })
      // Prune the skeleton when everything inside aged out.
      case simplifile.read_directory(directory) {
        Ok([]) -> {
          let _ = simplifile.delete(directory)
          Nil
        }
        _ -> Nil
      }
    }
  }
}

/// The natural spot if free, else "name (2).ext", "name (3).ext"… — the
/// same variant discipline as conflicted copies and path disambiguation.
/// The variant is woven into the BASENAME only (a dotted directory name
/// higher up must never be mistaken for the extension).
fn free_variant_of(destination: String, next: Int) -> String {
  case simplifile.is_file(destination), simplifile.is_directory(destination) {
    Ok(False), Ok(False) -> destination
    _, _ -> {
      let parent = parent_of(destination)
      let basename =
        destination |> string.split("/") |> list.last |> result.unwrap("")
      let #(stem, extension) = paths.split_extension(basename)
      let candidate = case extension {
        "" -> stem <> " (" <> int.to_string(next) <> ")"
        extension -> stem <> " (" <> int.to_string(next) <> ")." <> extension
      }
      let candidate = parent <> "/" <> candidate
      case simplifile.is_file(candidate) {
        Ok(False) -> candidate
        _ -> free_variant_of(destination, next + 1)
      }
    }
  }
}

fn parent_of(path: String) -> String {
  path
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> string.join("/")
}
