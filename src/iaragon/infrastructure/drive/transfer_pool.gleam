//// Executes the reconciler's download-only decisions against the local
//// mirror: blob downloads (streamed to disk via the injected fetch), folder
//// creation, Google-native and shortcut materialisation as .desktop link
//// files, and local deletions. Every success is recorded in the state owner
//// — that record IS what makes the file "synced".
////
//// A failed download is retried with the injected delay up to a small
//// bound, then dropped: the next reconciliation round re-decides it. One
//// actor processes transfers in order for now; a real worker pool can
//// replace the internals behind the same commands.

import filepath
import gleam/erlang/process.{type Name, type Subject}
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import iaragon/application/state_owner
import iaragon/domain/entry.{
  type NativeDocPolicy, type RemoteFile, Blob, Folder, GoogleNative, KnownFile,
  Shortcut,
}
import simplifile

pub type Command {
  EnqueueDownload(remote: RemoteFile)
  EnqueueDeleteLocal(file_id: String, path: String)
  /// Internal: a scheduled retry of a failed download.
  RetryDownload(remote: RemoteFile, failed_attempts: Int)
}

pub type TransferConfig {
  TransferConfig(
    root_dir: String,
    /// (file_id, absolute destination) — the authenticated streaming
    /// download, injected so tests never touch the network.
    fetch_to_disk: fn(String, String) -> Result(Nil, String),
    state_owner: Subject(state_owner.Command),
    native_policy: NativeDocPolicy,
    pick_retry_delay_ms: fn(Int) -> Int,
  )
}

const max_download_attempts = 4

type State {
  State(config: TransferConfig, self: Subject(Command))
}

pub fn supervised(
  name: Name(Command),
  config: TransferConfig,
) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name, config) })
}

pub fn start(
  name: Name(Command),
  config: TransferConfig,
) -> actor.StartResult(Subject(Command)) {
  actor.new(State(config: config, self: process.named_subject(name)))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    EnqueueDownload(remote) -> run_download(state, remote, 0)
    RetryDownload(remote, failed_attempts) ->
      run_download(state, remote, failed_attempts)
    EnqueueDeleteLocal(file_id, path) -> {
      let _ = simplifile.delete(state.config.root_dir <> "/" <> path)
      process.send(state.config.state_owner, state_owner.ForgetKnown(file_id))
      actor.continue(state)
    }
  }
}

fn run_download(
  state: State,
  remote: RemoteFile,
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  case materialize(state.config, remote) {
    Ok(Nil) -> {
      record_known(state.config, remote)
      actor.continue(state)
    }
    Error(_reason) -> {
      let failed_attempts = failed_attempts + 1
      case failed_attempts < max_download_attempts {
        True -> {
          let delay = state.config.pick_retry_delay_ms(failed_attempts - 1)
          process.send_after(
            state.self,
            delay,
            RetryDownload(remote, failed_attempts),
          )
          Nil
        }
        // Dropped on purpose: the next reconciliation round re-decides it.
        False -> Nil
      }
      actor.continue(state)
    }
  }
}

fn materialize(config: TransferConfig, remote: RemoteFile) -> Result(Nil, String) {
  let destination = config.root_dir <> "/" <> remote.path
  use Nil <- result.try(
    simplifile.create_directory_all(filepath.directory_name(destination))
    |> describe_error,
  )
  case remote.kind {
    Folder ->
      simplifile.create_directory_all(destination) |> describe_error
    Blob -> config.fetch_to_disk(remote.file_id, destination)
    // Export policies still materialise as links for now: exports are the
    // upload-phase FFI's sibling and land together with it. A link is safe —
    // never lossy, never overwritten by accident.
    GoogleNative -> write_link_file(destination, remote.name, remote.file_id)
    Shortcut(target_id) ->
      write_link_file(destination, remote.name, target_id)
  }
}

fn write_link_file(
  destination: String,
  name: String,
  file_id: String,
) -> Result(Nil, String) {
  let contents =
    "[Desktop Entry]\n"
    <> "Type=Link\n"
    <> "Name="
    <> name
    <> "\n"
    <> "URL=https://drive.google.com/open?id="
    <> file_id
    <> "\n"
  simplifile.write(to: destination, contents: contents) |> describe_error
}

fn record_known(config: TransferConfig, remote: RemoteFile) -> Nil {
  let destination = config.root_dir <> "/" <> remote.path
  let #(size, mtime_seconds) = case simplifile.file_info(destination) {
    Ok(info) -> #(info.size, info.mtime_seconds)
    Error(_) -> #(option.unwrap(remote.size, 0), 0)
  }
  process.send(
    config.state_owner,
    state_owner.PutKnown(KnownFile(
      file_id: remote.file_id,
      path: remote.path,
      remote_modified_time: remote.modified_time,
      md5: remote.md5,
      size: size,
      local_mtime_seconds: mtime_seconds,
      kind: remote.kind,
    )),
  )
}

fn describe_error(result: Result(a, simplifile.FileError)) -> Result(a, String) {
  result.map_error(result, simplifile.describe_error)
}
