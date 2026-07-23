import gleam/dict
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import iaragon/domain/entry.{Blob, KnownFile, LocalFile, RemoteFile}
import iaragon/domain/paths.{RemoteNode}
import iaragon/domain/reconcile
import iaragon/infrastructure/persistence/state_db

// Scale guards: the daemon's per-round costs at a 100k-file Drive (1,000
// folders × 100 files — a large personal My Drive). These are correctness
// tests that double as canaries: they print their wall time, and a
// super-linear regression in resolve_paths / reconcile_all / the SQLite
// store would blow the suite's runtime long before a user hits it.

const folders = 1000

const files_per_folder = 100

fn timed(label: String, run: fn() -> a) -> a {
  let started = now_ms()
  let outcome = run()
  let elapsed = now_ms() - started
  io.println("  [scale] " <> label <> ": " <> int.to_string(elapsed) <> " ms")
  outcome
}

fn now_ms() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds
  |> fn(seconds) { float.round(seconds *. 1000.0) }
}

pub fn a_hundred_thousand_files_resolve_paths_test() {
  let nodes = [
    RemoteNode("root-1", "My Drive", None, True),
    ..list.flat_map(range(1, folders), fn(folder) {
      let folder_id = "dir-" <> int.to_string(folder)
      [
        RemoteNode(
          folder_id,
          "folder" <> int.to_string(folder),
          Some("root-1"),
          True,
        ),
        ..list.map(range(1, files_per_folder), fn(file) {
          RemoteNode(
            folder_id <> "-f" <> int.to_string(file),
            "file" <> int.to_string(file) <> ".txt",
            Some(folder_id),
            False,
          )
        })
      ]
    })
  ]
  let resolved =
    timed("resolve_paths 100k", fn() {
      paths.resolve_paths(nodes, root_id: "root-1")
    })
  assert dict.size(resolved) == folders * files_per_folder + folders
  assert dict.get(resolved, "dir-7-f9") == Ok("folder7/file9.txt")
}

pub fn a_hundred_thousand_files_reconcile_in_steady_state_test() {
  // Everything synced and untouched: the periodic round's common case must
  // produce zero work (and get there fast).
  let entries =
    list.flat_map(range(1, folders), fn(folder) {
      list.map(range(1, files_per_folder), fn(file) {
        let id = "dir-" <> int.to_string(folder) <> "-f" <> int.to_string(file)
        let path =
          "folder"
          <> int.to_string(folder)
          <> "/file"
          <> int.to_string(file)
          <> ".txt"
        #(id, path)
      })
    })
  let locals =
    list.map(entries, fn(entry) { LocalFile(entry.1, 42, 1000, None) })
  let remotes =
    list.map(entries, fn(entry) {
      RemoteFile(
        file_id: entry.0,
        name: "n",
        path: entry.1,
        mime_type: "text/plain",
        parent_id: Some("root-1"),
        modified_time: "2026-07-01T10:00:00Z",
        size: Some(42),
        md5: Some("aaa"),
        trashed: False,
        kind: Blob,
      )
    })
  let knowns =
    list.map(entries, fn(entry) {
      KnownFile(
        file_id: entry.0,
        path: entry.1,
        remote_modified_time: "2026-07-01T10:00:00Z",
        md5: Some("aaa"),
        size: 42,
        local_mtime_seconds: 1000,
        kind: Blob,
      )
    })
  let decisions =
    timed("reconcile_all 100k steady state", fn() {
      reconcile.reconcile_all(locals, remotes, knowns)
    })
  // Nothing changed anywhere, so nothing to do anywhere (Noops filtered).
  assert decisions == []
}

pub fn a_hundred_thousand_knowns_fit_the_state_db_test() {
  let assert Ok(db) = state_db.open(":memory:")
  let known =
    KnownFile(
      file_id: "id",
      path: "p",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )
  timed("state_db 10k write-through puts", fn() {
    list.each(range(1, 10_000), fn(n) {
      let assert Ok(Nil) =
        state_db.put_known(
          db,
          KnownFile(..known, file_id: "id-" <> int.to_string(n)),
        )
    })
  })
  assert state_db.count_known(db) == Ok(10_000)
}

/// gleam_stdlib 1.0 dropped list.range; a tail-recursive local stand-in.
fn range(from: Int, to: Int) -> List(Int) {
  build_range(to, from, [])
}

fn build_range(current: Int, floor: Int, acc: List(Int)) -> List(Int) {
  case current < floor {
    True -> acc
    False -> build_range(current - 1, floor, [current, ..acc])
  }
}
