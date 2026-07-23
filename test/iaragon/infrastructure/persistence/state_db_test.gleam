import gleam/option.{None, Some}
import iaragon/domain/entry.{Blob, GoogleNative, KnownFile, Shortcut}
import iaragon/infrastructure/persistence/state_db
import simplifile

fn with_db(run: fn(state_db.Database) -> a) -> a {
  let assert Ok(db) = state_db.open(":memory:")
  run(db)
}

fn a_known(file_id: String, path: String) -> entry.KnownFile {
  KnownFile(
    file_id: file_id,
    path: path,
    remote_modified_time: "2026-07-01T10:00:00Z",
    md5: Some("aaa"),
    size: 42,
    local_mtime_seconds: 1000,
    kind: Blob,
  )
}

// PENTEST — the state DB maps every fileId to its path plus metadata: the
// user's entire Drive tree. World-readable, it discloses that tree to any
// local user. The DB file must be created owner-only (0600).
pub fn the_state_db_file_is_owner_only_test() {
  let dir = "build/test-scratch/state_db_perms"
  let path = dir <> "/state.db"
  let _ = simplifile.delete(path)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)

  let assert Ok(_db) = state_db.open(path)

  let assert Ok(info) = simplifile.file_info(path)
  assert simplifile.file_info_permissions_octal(info) == 0o600
}

pub fn known_files_survive_a_put_get_round_trip_test() {
  use db <- with_db
  let known = a_known("id-1", "docs/report.txt")
  let assert Ok(Nil) = state_db.put_known(db, known)
  assert state_db.get_known(db, "id-1") == Ok(Some(known))
}

pub fn every_file_kind_round_trips_test() {
  use db <- with_db
  let native =
    KnownFile(..a_known("id-n", "notes"), md5: None, kind: GoogleNative)
  let folder =
    KnownFile(..a_known("id-f", "docs"), md5: None, kind: entry.Folder)
  let shortcut =
    KnownFile(..a_known("id-s", "link"), md5: None, kind: Shortcut("id-target"))
  let assert Ok(Nil) = state_db.put_known(db, native)
  let assert Ok(Nil) = state_db.put_known(db, folder)
  let assert Ok(Nil) = state_db.put_known(db, shortcut)
  assert state_db.get_known(db, "id-n") == Ok(Some(native))
  assert state_db.get_known(db, "id-f") == Ok(Some(folder))
  assert state_db.get_known(db, "id-s") == Ok(Some(shortcut))
}

pub fn putting_the_same_file_id_replaces_the_record_test() {
  use db <- with_db
  let assert Ok(Nil) = state_db.put_known(db, a_known("id-1", "old.txt"))
  let renamed = a_known("id-1", "new.txt")
  let assert Ok(Nil) = state_db.put_known(db, renamed)
  assert state_db.get_known(db, "id-1") == Ok(Some(renamed))
  assert state_db.load_all_known(db) == Ok([renamed])
}

pub fn an_unknown_file_id_yields_none_test() {
  use db <- with_db
  assert state_db.get_known(db, "ghost") == Ok(None)
}

pub fn forgetting_removes_the_record_test() {
  use db <- with_db
  let assert Ok(Nil) = state_db.put_known(db, a_known("id-1", "a.txt"))
  let assert Ok(Nil) = state_db.forget_known(db, "id-1")
  assert state_db.get_known(db, "id-1") == Ok(None)
}

pub fn load_all_returns_records_ordered_by_path_test() {
  use db <- with_db
  let zebra = a_known("id-1", "zebra.txt")
  let apple = a_known("id-2", "apple.txt")
  let assert Ok(Nil) = state_db.put_known(db, zebra)
  let assert Ok(Nil) = state_db.put_known(db, apple)
  assert state_db.load_all_known(db) == Ok([apple, zebra])
}

pub fn the_page_token_starts_absent_and_round_trips_test() {
  use db <- with_db
  assert state_db.load_page_token(db) == Ok(None)
  let assert Ok(Nil) = state_db.save_page_token(db, "tok-1")
  assert state_db.load_page_token(db) == Ok(Some("tok-1"))
  let assert Ok(Nil) = state_db.save_page_token(db, "tok-2")
  assert state_db.load_page_token(db) == Ok(Some("tok-2"))
}

// The doctor reports the index size without loading every row into memory —
// a COUNT is the whole query.
pub fn counting_knowns_reports_the_index_size_test() {
  use db <- with_db
  assert state_db.count_known(db) == Ok(0)
  let assert Ok(Nil) = state_db.put_known(db, a_known("id-1", "a.txt"))
  let assert Ok(Nil) = state_db.put_known(db, a_known("id-2", "b.txt"))
  assert state_db.count_known(db) == Ok(2)
}
