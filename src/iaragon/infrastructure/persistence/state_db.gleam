//// SQLite persistence for the "last known synced state" — the decided
//// storage (fileId ↔ path with sync-time metadata, plus the Changes API
//// page token). SQLite over DETS/Mnesia for: lookup by two keys, atomic
//// batches, and easy inspection with the sqlite3 CLI.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import iaragon/application/state_owner
import iaragon/domain/entry.{
  type KnownFile, Blob, Folder, GoogleNative, KnownFile, Shortcut,
}
import simplifile
import sqlight

pub type Database {
  Database(connection: sqlight.Connection)
}

const create_schema = "
  CREATE TABLE IF NOT EXISTS known_files (
    file_id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    remote_modified_time TEXT NOT NULL,
    md5 TEXT,
    size INTEGER NOT NULL,
    local_mtime_seconds INTEGER NOT NULL,
    kind TEXT NOT NULL,
    shortcut_target TEXT
  );
  CREATE INDEX IF NOT EXISTS known_files_by_path ON known_files (path);
  CREATE TABLE IF NOT EXISTS sync_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
"

/// Open (or create) the database and ensure the schema exists.
pub fn open(path: String) -> Result(Database, sqlight.Error) {
  use connection <- result.try(sqlight.open(path))
  use Nil <- result.try(sqlight.exec(create_schema, connection))
  // The DB indexes the user's entire Drive tree (every fileId↔path plus
  // metadata); a world-readable file would disclose it to other local users.
  // Lock it to the owner. Best-effort: an in-memory (":memory:") DB has no
  // file, and the composition root also restricts the parent dir to 0700.
  let _ = simplifile.set_permissions_octal(path, 0o600)
  Ok(Database(connection))
}

/// Adapt this database to the state owner's persistence port.
pub fn build_state_store(db: Database) -> state_owner.StateStore {
  state_owner.StateStore(
    load_all_known: fn() { load_all_known(db) |> describe_error },
    load_page_token: fn() { load_page_token(db) |> describe_error },
    put_known: fn(file) { put_known(db, file) |> describe_error },
    forget_known: fn(file_id) { forget_known(db, file_id) |> describe_error },
    save_page_token: fn(token) { save_page_token(db, token) |> describe_error },
  )
}

fn describe_error(result: Result(a, sqlight.Error)) -> Result(a, String) {
  result.map_error(result, string.inspect)
}

pub fn put_known(db: Database, file: KnownFile) -> Result(Nil, sqlight.Error) {
  let #(kind, shortcut_target) = encode_kind(file.kind)
  sqlight.query(
    "INSERT INTO known_files
       (file_id, path, remote_modified_time, md5, size, local_mtime_seconds,
        kind, shortcut_target)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (file_id) DO UPDATE SET
       path = excluded.path,
       remote_modified_time = excluded.remote_modified_time,
       md5 = excluded.md5,
       size = excluded.size,
       local_mtime_seconds = excluded.local_mtime_seconds,
       kind = excluded.kind,
       shortcut_target = excluded.shortcut_target",
    on: db.connection,
    with: [
      sqlight.text(file.file_id),
      sqlight.text(file.path),
      sqlight.text(file.remote_modified_time),
      sqlight.nullable(sqlight.text, file.md5),
      sqlight.int(file.size),
      sqlight.int(file.local_mtime_seconds),
      sqlight.text(kind),
      sqlight.nullable(sqlight.text, shortcut_target),
    ],
    expecting: decode.success(Nil),
  )
  |> replace_rows_with_nil
}

pub fn get_known(
  db: Database,
  file_id: String,
) -> Result(Option(KnownFile), sqlight.Error) {
  use rows <- result.try(sqlight.query(
    select_known_sql <> " WHERE file_id = ?",
    on: db.connection,
    with: [sqlight.text(file_id)],
    expecting: known_file_decoder(),
  ))
  Ok(list.first(rows) |> option.from_result)
}

pub fn load_all_known(db: Database) -> Result(List(KnownFile), sqlight.Error) {
  sqlight.query(
    select_known_sql <> " ORDER BY path",
    on: db.connection,
    with: [],
    expecting: known_file_decoder(),
  )
}

pub fn forget_known(
  db: Database,
  file_id: String,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "DELETE FROM known_files WHERE file_id = ?",
    on: db.connection,
    with: [sqlight.text(file_id)],
    expecting: decode.success(Nil),
  )
  |> replace_rows_with_nil
}

pub fn save_page_token(
  db: Database,
  token: String,
) -> Result(Nil, sqlight.Error) {
  sqlight.query(
    "INSERT INTO sync_meta (key, value) VALUES ('page_token', ?)
     ON CONFLICT (key) DO UPDATE SET value = excluded.value",
    on: db.connection,
    with: [sqlight.text(token)],
    expecting: decode.success(Nil),
  )
  |> replace_rows_with_nil
}

pub fn load_page_token(db: Database) -> Result(Option(String), sqlight.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT value FROM sync_meta WHERE key = 'page_token'",
      on: db.connection,
      with: [],
      expecting: {
        use value <- decode.field(0, decode.string)
        decode.success(value)
      },
    ),
  )
  Ok(list.first(rows) |> option.from_result)
}

const select_known_sql = "
  SELECT file_id, path, remote_modified_time, md5, size, local_mtime_seconds,
         kind, shortcut_target
  FROM known_files
"

fn known_file_decoder() -> decode.Decoder(KnownFile) {
  use file_id <- decode.field(0, decode.string)
  use path <- decode.field(1, decode.string)
  use remote_modified_time <- decode.field(2, decode.string)
  use md5 <- decode.field(3, decode.optional(decode.string))
  use size <- decode.field(4, decode.int)
  use local_mtime_seconds <- decode.field(5, decode.int)
  use kind <- decode.field(6, decode.string)
  use shortcut_target <- decode.field(7, decode.optional(decode.string))
  decode.success(KnownFile(
    file_id:,
    path:,
    remote_modified_time:,
    md5:,
    size:,
    local_mtime_seconds:,
    kind: decode_kind(kind, shortcut_target),
  ))
}

fn encode_kind(kind: entry.FileKind) -> #(String, Option(String)) {
  case kind {
    Blob -> #("blob", None)
    GoogleNative -> #("native", None)
    Folder -> #("folder", None)
    Shortcut(target_id) -> #("shortcut", Some(target_id))
  }
}

fn decode_kind(
  kind: String,
  shortcut_target: Option(String),
) -> entry.FileKind {
  case kind, shortcut_target {
    "shortcut", Some(target_id) -> Shortcut(target_id)
    "native", _ -> GoogleNative
    "folder", _ -> Folder
    _, _ -> Blob
  }
}

fn replace_rows_with_nil(
  rows: Result(List(Nil), sqlight.Error),
) -> Result(Nil, sqlight.Error) {
  result.replace(rows, Nil)
}
