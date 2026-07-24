import gleam/string
import iaragon/infrastructure/fs/local_trash
import simplifile

// The local safety net: a mirror copy deleted because the remote was
// trashed is MOVED into .iaragon-trash/ inside the mirror (same
// filesystem, atomic rename) instead of unlinked — every mature sync tool
// keeps some local recovery path (.stversions, .dropbox.cache,
// --backup-dir). A boot-time sweep applies the retention.

const scratch = "build/test-scratch/local-trash"

fn fresh_root(name: String) -> String {
  let root = scratch <> "/" <> name
  let _ = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
  root
}

pub fn a_trashed_file_keeps_its_bytes_and_relative_path_test() {
  let root = fresh_root("keeps")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/docs")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/docs/report.txt", contents: "precious")

  let assert Ok(Nil) = local_trash.move_to_trash(root, "docs/report.txt")

  assert simplifile.is_file(root <> "/docs/report.txt") == Ok(False)
  assert simplifile.read(root <> "/.iaragon-trash/docs/report.txt")
    == Ok("precious")
}

pub fn a_second_deletion_of_the_same_path_gets_a_variant_test() {
  let root = fresh_root("variants")
  let assert Ok(Nil) = simplifile.write(to: root <> "/note.txt", contents: "v1")
  let assert Ok(Nil) = local_trash.move_to_trash(root, "note.txt")
  let assert Ok(Nil) = simplifile.write(to: root <> "/note.txt", contents: "v2")

  let assert Ok(Nil) = local_trash.move_to_trash(root, "note.txt")

  // Both survive: the original at the natural spot, the newer as a variant.
  assert simplifile.read(root <> "/.iaragon-trash/note.txt") == Ok("v1")
  let assert Ok(entries) = simplifile.read_directory(root <> "/.iaragon-trash")
  assert list_count_prefixed(entries, "note") == 2
}

pub fn the_sweep_removes_only_entries_past_retention_test() {
  let root = fresh_root("sweep")
  let trash = root <> "/.iaragon-trash"
  let assert Ok(Nil) = simplifile.create_directory_all(trash <> "/old-dir")
  let assert Ok(Nil) = simplifile.write(to: trash <> "/old.txt", contents: "x")
  let assert Ok(Nil) =
    simplifile.write(to: trash <> "/old-dir/older.txt", contents: "x")
  let assert Ok(Nil) = simplifile.write(to: trash <> "/new.txt", contents: "x")
  // Age the two "old" entries by faking their mtime into the past.
  let assert Ok(Nil) = set_mtime(trash <> "/old.txt", 1000)
  let assert Ok(Nil) = set_mtime(trash <> "/old-dir/older.txt", 1000)

  // The sweep reports WHAT it destroyed (trash-relative, sorted) — the one
  // record that survives the destruction, so a boot that emptied the trash
  // is explainable from the journal instead of a forensic mystery.
  assert local_trash.sweep(
      root,
      now_unix: 4_000_000,
      retention_seconds: 1_000_000,
    )
    == ["old-dir/older.txt", "old.txt"]

  assert simplifile.is_file(trash <> "/old.txt") == Ok(False)
  assert simplifile.is_file(trash <> "/old-dir/older.txt") == Ok(False)
  assert simplifile.is_file(trash <> "/new.txt") == Ok(True)
}

pub fn sweeping_without_a_trash_dir_is_a_noop_test() {
  let root = fresh_root("no-trash")
  assert local_trash.sweep(root, now_unix: 4_000_000, retention_seconds: 1)
    == []
  assert simplifile.is_directory(root <> "/.iaragon-trash") == Ok(False)
}

fn list_count_prefixed(entries: List(String), prefix: String) -> Int {
  case entries {
    [] -> 0
    [first, ..rest] ->
      case string.starts_with(first, prefix) {
        True -> 1 + list_count_prefixed(rest, prefix)
        False -> list_count_prefixed(rest, prefix)
      }
  }
}

@external(erlang, "iaragon_touch_ffi", "set_mtime")
fn set_mtime(path: String, mtime_unix: Int) -> Result(Nil, String)

pub fn a_freshly_trashed_old_file_survives_the_sweep_test() {
  // `rename` preserves mtime, so judging age by the file's own mtime would
  // measure "when was the content last edited", not "when was it trashed" —
  // an old file deleted today would be swept at the very next boot, with an
  // effective recovery window of zero. Trashing must restart the clock.
  let root = fresh_root("fresh-trash")
  let assert Ok(Nil) =
    simplifile.write(to: root <> "/ancient.txt", contents: "x")
  // Content last edited long before the retention window.
  let assert Ok(Nil) = set_mtime(root <> "/ancient.txt", 1000)

  let assert Ok(Nil) = local_trash.move_to_trash(root, "ancient.txt")
  local_trash.sweep(root, now_unix: 4_000_000, retention_seconds: 1_000_000)

  assert simplifile.is_file(root <> "/.iaragon-trash/ancient.txt") == Ok(True)
}
