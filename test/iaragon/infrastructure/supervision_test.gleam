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

pub fn daemon_tree_starts_and_actors_respond_test() {
  let assert Ok(daemon) = supervision.start_daemon()

  // The state owner does real (in-memory) work: page token round-trip…
  assert process.call(
      daemon.state_owner,
      call_timeout,
      state_owner.GetPageToken,
    )
    == None
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

  // The four stubs are alive under the supervisor and answer a ping.
  assert process.call(daemon.local_watcher, call_timeout, local_watcher.Ping)
    == Nil
  assert process.call(daemon.remote_poller, call_timeout, remote_poller.Ping)
    == Nil
  assert process.call(daemon.reconciler, call_timeout, reconciler.Ping) == Nil
  assert process.call(daemon.transfer_pool, call_timeout, transfer_pool.Ping)
    == Nil
}
