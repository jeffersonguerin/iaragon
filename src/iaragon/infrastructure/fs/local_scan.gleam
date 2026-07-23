//// Snapshot of the local mirror: every regular file with its cheap metadata
//// (size + mtime; md5 stays absent — the reconciler hashes on demand only
//// when it must disambiguate). In-flight downloads live in reserved
//// `.iaragon-partial/` control directories, which the scan skips wholesale —
//// a structural exclusion by LOCATION, so a real Drive file whose name merely
//// ends in `.iaragon-partial` still syncs. A missing root is created empty:
//// the first run of a fresh machine starts from nothing.
////
//// The walk uses lstat (`link_info`) and NEVER follows symlinks: a symlink
//// inside the mirror would otherwise upload its target's bytes to Drive
//// (exfiltrating files from outside the mirror) and a symlink cycle would
//// loop the scan forever. Symlinks and special files (sockets, devices)
//// are simply skipped.

import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import iaragon/domain/entry.{type LocalFile, LocalFile}
import simplifile

/// Reserved directory (in every mirror folder) holding in-flight partial
/// downloads. Skipped by the scan so a half-written file is never seen as a
/// new local file — and, unlike the old name-suffix rule, a real Drive file
/// that merely ends in this string is no longer hidden.
const partial_dir_name = ".iaragon-partial"

pub fn scan_mirror(root_dir: String) -> Result(List(LocalFile), String) {
  use Nil <- result.try(
    simplifile.create_directory_all(root_dir) |> describe_error,
  )
  walk(root_dir, root_dir)
}

fn walk(dir: String, root_dir: String) -> Result(List(LocalFile), String) {
  use names <- result.try(simplifile.read_directory(dir) |> describe_error)
  list.try_fold(names, [], fn(acc, name) {
    case name == partial_dir_name {
      // Control directory for in-flight downloads — never part of the mirror.
      True -> Ok(acc)
      False -> {
        let full = dir <> "/" <> name
        // lstat: a symlink reports as Symlink here instead of its target's
        // type. A file the user deletes between read_directory and here just
        // vanishes from this scan — skip it rather than failing the whole
        // round (which would crash the reconciler and drop its model +
        // pending sets).
        case simplifile.link_info(full) {
          Error(_) -> Ok(acc)
          Ok(info) -> entry_of(info, full, root_dir, acc)
        }
      }
    }
  })
}

fn entry_of(
  info: simplifile.FileInfo,
  full: String,
  root_dir: String,
  acc: List(LocalFile),
) -> Result(List(LocalFile), String) {
  case simplifile.file_info_type(info) {
    // Never follow a symlink (exfiltration / cycle) and never mirror a
    // socket/device.
    simplifile.Symlink | simplifile.Other -> Ok(acc)
    simplifile.Directory -> {
      use nested <- result.try(walk(full, root_dir))
      Ok(list.append(acc, nested))
    }
    simplifile.File ->
      Ok([
        LocalFile(
          path: strip_root(full, root_dir),
          size: info.size,
          mtime_seconds: info.mtime_seconds,
          md5: None,
        ),
        ..acc
      ])
  }
}

fn strip_root(path: String, root_dir: String) -> String {
  case string.split_once(path, root_dir <> "/") {
    Ok(#("", relative)) -> relative
    _ -> path
  }
}

fn describe_error(
  result: Result(a, simplifile.FileError),
) -> Result(a, String) {
  result.map_error(result, simplifile.describe_error)
}
