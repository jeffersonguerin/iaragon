import gleam/list
import gleam/option.{None}
import gleam/string
import iaragon/domain/entry.{LocalFile}
import iaragon/infrastructure/fs/local_scan
import simplifile

const scratch_dir = "build/test-scratch/local_scan"

pub fn files_are_listed_recursively_with_relative_paths_test() {
  let root = scratch_dir <> "/nested"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/docs")
  let assert Ok(Nil) = simplifile.write(to: root <> "/a.txt", contents: "aa")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/docs/b.txt", contents: "bbb")

  let assert Ok(scanned) = local_scan.scan_mirror(root)
  let by_path =
    list.sort(scanned, fn(a: entry.LocalFile, b: entry.LocalFile) {
      string.compare(a.path, b.path)
    })
  let assert [
    LocalFile(path: "a.txt", size: 2, md5: None, mtime_seconds: mtime_a),
    LocalFile(path: "docs/b.txt", size: 3, md5: None, mtime_seconds: mtime_b),
  ] = by_path
  assert mtime_a > 0
  assert mtime_b > 0
}

pub fn partial_download_files_are_ignored_test() {
  let root = scratch_dir <> "/partials"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) = simplifile.write(to: root <> "/ok.txt", contents: "x")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/big.bin.iaragon-partial", contents: "half")

  let assert Ok(scanned) = local_scan.scan_mirror(root)
  assert list.map(scanned, fn(file) { file.path }) == ["ok.txt"]
}

// Symlinks inside the mirror are NOT followed: a link would otherwise get
// its target's bytes uploaded to Drive (exfiltration of files outside the
// mirror, e.g. a link to ~/.ssh), and a link cycle would loop the scan.
pub fn symlinks_are_not_followed_test() {
  let root = scratch_dir <> "/symlinks"
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  let assert Ok(Nil) = simplifile.write(to: root <> "/real.txt", contents: "hi")
  // A secret outside the mirror, and a symlink to it inside.
  let outside = scratch_dir <> "/outside-secret.txt"
  let assert Ok(Nil) = simplifile.write(to: outside, contents: "secret")
  let assert Ok(Nil) =
    simplifile.create_symlink(to: outside, from: root <> "/link.txt")
  // A symlinked directory must not be recursed into either.
  let assert Ok(Nil) =
    simplifile.create_symlink(to: scratch_dir, from: root <> "/loop")

  let assert Ok(scanned) = local_scan.scan_mirror(root)
  assert list.map(scanned, fn(file) { file.path }) == ["real.txt"]
}

pub fn a_missing_mirror_root_is_created_empty_test() {
  let root = scratch_dir <> "/brand-new"
  let assert Ok([]) = local_scan.scan_mirror(root)
  assert simplifile.is_directory(root) == Ok(True)
}
