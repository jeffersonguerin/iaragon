//// Snapshot of the local mirror: every regular file with its cheap metadata
//// (size + mtime; md5 stays absent — the reconciler hashes on demand only
//// when it must disambiguate). In-flight `.iaragon-partial` downloads are
//// not part of the mirror. A missing root is created empty: the first run
//// of a fresh machine starts from nothing.

import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import iaragon/domain/entry.{type LocalFile, LocalFile}
import simplifile

const partial_suffix = ".iaragon-partial"

pub fn scan_mirror(root_dir: String) -> Result(List(LocalFile), String) {
  use Nil <- result.try(
    simplifile.create_directory_all(root_dir) |> describe_error,
  )
  use paths <- result.try(simplifile.get_files(in: root_dir) |> describe_error)
  paths
  |> list.filter(fn(path) { !string.ends_with(path, partial_suffix) })
  |> list.try_map(fn(path) {
    use info <- result.try(simplifile.file_info(path) |> describe_error)
    Ok(LocalFile(
      path: strip_root(path, root_dir),
      size: info.size,
      mtime_seconds: info.mtime_seconds,
      md5: None,
    ))
  })
}

fn strip_root(path: String, root_dir: String) -> String {
  case string.split_once(path, root_dir <> "/") {
    Ok(#("", relative)) -> relative
    _ -> path
  }
}

fn describe_error(result: Result(a, simplifile.FileError)) -> Result(a, String) {
  result.map_error(result, simplifile.describe_error)
}
