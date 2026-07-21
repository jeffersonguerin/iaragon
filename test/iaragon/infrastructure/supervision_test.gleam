import gleam/erlang/process
import gleam/option.{None, Some}
import iaragon/application/reconciler
import iaragon/application/state_owner
import iaragon/domain/entry.{Blob, KnownFile}
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/transfer_pool
import iaragon/infrastructure/fs/local_watcher
import iaragon/infrastructure/supervision

const call_timeout = 500

fn an_ephemeral_store() -> state_owner.StateStore {
  state_owner.StateStore(
    load_all_known: fn() { Ok([]) },
    load_page_token: fn() { Ok(None) },
    put_known: fn(_file) { Ok(Nil) },
    forget_known: fn(_file_id) { Ok(Nil) },
    save_page_token: fn(_token) { Ok(Nil) },
  )
}

fn an_idle_drive_port() -> remote_poller.DrivePort {
  remote_poller.DrivePort(
    fetch_start_page_token: fn() { Ok("tok-boot") },
    fetch_all_changes: fn(_page_token) { Error("not under test") },
  )
}

pub fn daemon_tree_starts_and_actors_respond_test() {
  let deliver = process.new_subject()
  let assert Ok(daemon) =
    supervision.start_daemon(
      store: an_ephemeral_store(),
      drive: an_idle_drive_port(),
      deliver_changes: deliver,
      mirror_root: "build/test-scratch/supervision/mirror",
      fetch_to_disk: fn(_file_id, _destination) { Error("not under test") },
      native_policy: entry.LinkFile,
    )

  // No page token yet, so the first poll bootstraps one through the tree:
  // poller → drive port → state owner.
  assert process.call(
      daemon.state_owner,
      call_timeout,
      state_owner.GetPageToken,
    )
    == None
  process.send(daemon.remote_poller, remote_poller.Poll)
  assert wait_for_page_token(daemon.state_owner, Some("tok-boot"))

  // The state owner does real (in-memory) work: page token round-trip…
  process.send(daemon.state_owner, state_owner.SetPageToken("token-1"))
  assert process.call(
      daemon.state_owner,
      call_timeout,
      state_owner.GetPageToken,
    )
    == Some("token-1")

  // …and known-file round-trip, including forgetting.
  let known =
    KnownFile(
      file_id: "id-1",
      path: "docs/report.txt",
      remote_modified_time: "2026-07-01T10:00:00Z",
      md5: Some("aaa"),
      size: 42,
      local_mtime_seconds: 1000,
      kind: Blob,
    )
  process.send(daemon.state_owner, state_owner.PutKnown(known))
  assert process.call(daemon.state_owner, call_timeout, state_owner.GetKnown(
      "id-1",
      _,
    ))
    == Some(known)
  process.send(daemon.state_owner, state_owner.ForgetKnown("id-1"))
  assert process.call(daemon.state_owner, call_timeout, state_owner.GetKnown(
      "id-1",
      _,
    ))
    == None

  // The transfer pool is alive: a folder download needs no network and ends
  // recorded in the state owner.
  let probe =
    entry.RemoteFile(
      file_id: "id-probe",
      name: "probe",
      path: "probe",
      mime_type: "application/vnd.google-apps.folder",
      parent_id: None,
      modified_time: "2026-07-01T10:00:00Z",
      size: None,
      md5: None,
      trashed: False,
      kind: entry.Folder,
    )
  process.send(daemon.transfer_pool, transfer_pool.EnqueueDownload(probe))
  assert retry_until(40, fn() {
    process.call(daemon.state_owner, call_timeout, state_owner.GetKnown(
      "id-probe",
      _,
    ))
    != None
  })

  // The remaining stubs are alive under the supervisor and answer a ping.
  assert process.call(daemon.local_watcher, call_timeout, local_watcher.Ping)
    == Nil
  assert process.call(daemon.reconciler, call_timeout, reconciler.Ping) == Nil
}

fn wait_for_page_token(
  owner: process.Subject(state_owner.Command),
  expected: option.Option(String),
) -> Bool {
  retry_until(40, fn() {
    process.call(owner, call_timeout, state_owner.GetPageToken) == expected
  })
}

fn retry_until(attempts: Int, check: fn() -> Bool) -> Bool {
  case check() {
    True -> True
    False ->
      case attempts <= 1 {
        True -> False
        False -> {
          process.sleep(25)
          retry_until(attempts - 1, check)
        }
      }
  }
}
