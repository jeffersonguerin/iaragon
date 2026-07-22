//// Executes the reconciler's transfer decisions against the local mirror
//// and Drive. Downloads: blobs (streamed via the injected fetch), folders,
//// Google-native and shortcut materialisation as .desktop links, local
//// deletions. Uploads: resumable pushes (create or update-in-place), remote
//// folder creation for paths that do not exist on Drive yet (cached, so
//// sibling uploads never create the same folder twice), and trashing.
////
//// Every success is recorded in the state owner — that record IS what makes
//// a file "synced" — and upload/trash outcomes are settled back to the
//// reconciler so its remote model and in-flight bookkeeping stay honest.
//// Failures retry with the injected delay up to a small bound, then settle
//// as failures (uploads/trash) or are dropped (downloads): the next
//// reconciliation round re-decides. One actor processes transfers in order
//// for now; a real worker pool can replace the internals behind the same
//// commands.

import filepath
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import iaragon/application/reconciler.{type RemoteSighting, type UploadPlan}
import iaragon/application/state_owner
import iaragon/domain/entry.{
  type NativeDocPolicy, type RemoteFile, Blob, Folder, GoogleNative, KnownFile,
  Shortcut,
}
import iaragon/domain/paths
import iaragon/infrastructure/drive/changes.{type ChangedFile}
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/upload.{type UploadTarget}
import simplifile

pub type Command {
  EnqueueDownload(remote: RemoteFile)
  EnqueueDeleteLocal(file_id: String, path: String)
  EnqueueUpload(plan: UploadPlan)
  EnqueueTrashRemote(file_id: String)
  /// Resolve an edit-edit conflict: move the local version aside to
  /// `copy_path` (it syncs up as a new file on the next round) and download
  /// the remote version onto the original path.
  EnqueueConflictCopy(remote: RemoteFile, copy_path: String)
  /// Apply a remote rename/move: relocate the mirror copy from `from` to
  /// `updated.path` and record the updated known state. Idempotent — a file
  /// already carried to its destination (e.g. by a parent folder rename)
  /// only gets its bookkeeping.
  EnqueueMoveLocal(updated: entry.KnownFile, from: String)
  /// Internal: scheduled retries of failed transfers.
  RetryDownload(remote: RemoteFile, failed_attempts: Int)
  RetryUpload(plan: UploadPlan, failed_attempts: Int)
  RetryTrash(file_id: String, failed_attempts: Int)
  RetryConflictCopy(remote: RemoteFile, copy_path: String, failed_attempts: Int)
}

/// The authenticated Drive operations, grouped so the composition root can
/// hand them over in one piece.
pub type DriveTransferOps {
  DriveTransferOps(
    fetch_to_disk: fn(String, String) -> Result(Nil, String),
    upload_to_drive: fn(UploadTarget, String, Int) ->
      Result(ChangedFile, String),
    create_remote_folder: fn(String, String) -> Result(ChangedFile, String),
    trash_remote: fn(String) -> Result(Nil, String),
  )
}

pub type TransferConfig {
  TransferConfig(
    root_dir: String,
    /// (file_id, absolute destination) — the authenticated streaming
    /// download, injected so tests never touch the network.
    fetch_to_disk: fn(String, String) -> Result(Nil, String),
    /// (target, absolute source, total size) — the resumable upload.
    upload_to_drive: fn(UploadTarget, String, Int) ->
      Result(ChangedFile, String),
    create_remote_folder: fn(String, String) -> Result(ChangedFile, String),
    trash_remote: fn(String) -> Result(Nil, String),
    /// Outcome feedback into the reconciler (path / file_id keyed).
    settle_upload: fn(String, Result(RemoteSighting, String)) -> Nil,
    settle_trash: fn(String, Result(Nil, String)) -> Nil,
    settle_conflict: fn(String, Result(Nil, String)) -> Nil,
    /// Folders created on the way to an upload enter the remote model here.
    observe_folder: fn(RemoteSighting) -> Nil,
    state_owner: Subject(state_owner.Command),
    native_policy: NativeDocPolicy,
    pick_retry_delay_ms: fn(Int) -> Int,
  )
}

const max_transfer_attempts = 4

type State {
  State(
    config: TransferConfig,
    self: Subject(Command),
    /// parent_id <> "/" <> name → created folder id, so sibling uploads in a
    /// brand-new folder never create it twice while the remote model still
    /// lags behind.
    created_folders: Dict(String, String),
  )
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
  actor.new(State(
    config: config,
    self: process.named_subject(name),
    created_folders: dict.new(),
  ))
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  case command {
    EnqueueDownload(remote) -> run_download(state, remote, 0)
    RetryDownload(remote, failed_attempts) ->
      run_download(state, remote, failed_attempts)
    EnqueueDeleteLocal(file_id, path) -> {
      let _ = simplifile.delete(state.config.root_dir <> "/" <> path)
      process.send(state.config.state_owner, state_owner.ForgetKnown(file_id))
      actor.continue(state)
    }
    EnqueueUpload(plan) -> run_upload(state, plan, 0)
    RetryUpload(plan, failed_attempts) ->
      run_upload(state, plan, failed_attempts)
    EnqueueTrashRemote(file_id) -> run_trash(state, file_id, 0)
    RetryTrash(file_id, failed_attempts) ->
      run_trash(state, file_id, failed_attempts)
    EnqueueMoveLocal(updated, from) -> {
      run_move_local(state.config, updated, from)
      actor.continue(state)
    }
    EnqueueConflictCopy(remote, copy_path) ->
      run_conflict_copy(state, remote, copy_path, 0)
    RetryConflictCopy(remote, copy_path, failed_attempts) ->
      run_conflict_copy(state, remote, copy_path, failed_attempts)
  }
}

// --- Local moves (remote renames) ------------------------------------------------

/// Known state is only updated when the destination really holds the file:
/// a failed rename leaves the old bookkeeping in place, and the next round
/// re-decides the move.
fn run_move_local(
  config: TransferConfig,
  updated: entry.KnownFile,
  from: String,
) -> Nil {
  let source = config.root_dir <> "/" <> from
  let destination = config.root_dir <> "/" <> updated.path
  let moved = {
    use Nil <- result.try(
      simplifile.create_directory_all(filepath.directory_name(destination))
      |> describe_error,
    )
    case source_exists(source), destination_exists(destination) {
      True, False -> simplifile.rename(at: source, to: destination) |> describe_error
      // Already carried to its destination (e.g. by a parent folder rename).
      False, True -> Ok(Nil)
      False, False -> Error("neither source nor destination exists")
      // Both exist: something else occupies the destination — leave the
      // filesystem alone and let the next round reconcile the difference.
      True, True -> Error("destination already occupied")
    }
  }
  case moved {
    Ok(Nil) ->
      process.send(config.state_owner, state_owner.PutKnown(updated))
    Error(_reason) -> Nil
  }
}

fn source_exists(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
  || simplifile.is_directory(path) == Ok(True)
}

fn destination_exists(path: String) -> Bool {
  simplifile.is_file(path) == Ok(True)
  || simplifile.is_directory(path) == Ok(True)
}

// --- Conflicted copies ----------------------------------------------------------

fn run_conflict_copy(
  state: State,
  remote: RemoteFile,
  copy_path: String,
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  let outcome = {
    use Nil <- result.try(move_local_aside(state.config, remote.path, copy_path))
    use Nil <- result.try(materialize(state.config, remote))
    Ok(Nil)
  }
  case outcome {
    Ok(Nil) -> {
      record_downloaded(state.config, remote)
      state.config.settle_conflict(remote.path, Ok(Nil))
      actor.continue(state)
    }
    Error(reason) -> {
      retry_or(
        state,
        failed_attempts,
        fn(attempts) { RetryConflictCopy(remote, copy_path, attempts) },
        give_up: fn() {
          state.config.settle_conflict(remote.path, Error(reason))
        },
      )
      actor.continue(state)
    }
  }
}

/// Rename the local original to the conflicted-copy path, never overwriting:
/// an already-taken name gets a numeric variant. A retry after a successful
/// move (original absent) is a no-op.
fn move_local_aside(
  config: TransferConfig,
  original_path: String,
  copy_path: String,
) -> Result(Nil, String) {
  let source = config.root_dir <> "/" <> original_path
  case simplifile.is_file(source) {
    Ok(True) ->
      simplifile.rename(
        at: source,
        to: config.root_dir <> "/" <> pick_free_variant(config, copy_path, 2),
      )
      |> describe_error
    _ -> Ok(Nil)
  }
}

fn pick_free_variant(
  config: TransferConfig,
  copy_path: String,
  next_suffix: Int,
) -> String {
  case simplifile.is_file(config.root_dir <> "/" <> copy_path) {
    Ok(True) -> {
      let #(stem, extension) = paths.split_extension(copy_path)
      let variant = case extension {
        "" -> stem <> " (" <> int.to_string(next_suffix) <> ")"
        extension ->
          stem <> " (" <> int.to_string(next_suffix) <> ")." <> extension
      }
      // The variant candidates share the dated stem, so recursion always
      // terminates at the first free number.
      case simplifile.is_file(config.root_dir <> "/" <> variant) {
        Ok(True) -> pick_free_variant(config, copy_path, next_suffix + 1)
        _ -> variant
      }
    }
    _ -> copy_path
  }
}

// --- Downloads ----------------------------------------------------------------

fn run_download(
  state: State,
  remote: RemoteFile,
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  case materialize(state.config, remote) {
    Ok(Nil) -> {
      record_downloaded(state.config, remote)
      actor.continue(state)
    }
    Error(_reason) -> {
      // Dropped after the last attempt: the next round re-decides it.
      retry_or(
        state,
        failed_attempts,
        fn(attempts) { RetryDownload(remote, attempts) },
        give_up: fn() { Nil },
      )
      actor.continue(state)
    }
  }
}

fn materialize(
  config: TransferConfig,
  remote: RemoteFile,
) -> Result(Nil, String) {
  let destination = config.root_dir <> "/" <> remote.path
  use Nil <- result.try(
    simplifile.create_directory_all(filepath.directory_name(destination))
    |> describe_error,
  )
  case remote.kind {
    Folder -> simplifile.create_directory_all(destination) |> describe_error
    Blob -> config.fetch_to_disk(remote.file_id, destination)
    // Export policies still materialise as links for now: exports land
    // together with the rest of the native-doc work. A link is safe — never
    // lossy, never overwritten by accident.
    GoogleNative -> write_link_file(destination, remote.name, remote.file_id)
    Shortcut(target_id) -> write_link_file(destination, remote.name, target_id)
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

fn record_downloaded(config: TransferConfig, remote: RemoteFile) -> Nil {
  record_known(
    config,
    remote.file_id,
    remote.path,
    remote.modified_time,
    remote.md5,
    option.unwrap(remote.size, 0),
    remote.kind,
  )
}

// --- Uploads ------------------------------------------------------------------

fn run_upload(
  state: State,
  plan: UploadPlan,
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  case ensure_remote_folders(state, plan) {
    Ok(#(state, parent_id)) ->
      case push_file(state.config, plan, parent_id) {
        Ok(Nil) -> actor.continue(state)
        Error(reason) -> {
          settle_upload_or_retry(state, plan, failed_attempts, reason)
          actor.continue(state)
        }
      }
    Error(reason) -> {
      settle_upload_or_retry(state, plan, failed_attempts, reason)
      actor.continue(state)
    }
  }
}

/// Create the plan's missing folder chain (outermost first), reusing ids of
/// folders this pool already created. Returns the final parent id.
fn ensure_remote_folders(
  state: State,
  plan: UploadPlan,
) -> Result(#(State, String), String) {
  list.try_fold(
    plan.missing_folders,
    #(state, plan.anchor_parent_id),
    fn(acc, folder_name) {
      let #(state, parent_id) = acc
      let cache_key = parent_id <> "/" <> folder_name
      case dict.get(state.created_folders, cache_key) {
        Ok(folder_id) -> Ok(#(state, folder_id))
        Error(Nil) -> {
          use created <- result.try(state.config.create_remote_folder(
            folder_name,
            parent_id,
          ))
          state.config.observe_folder(remote_poller.translate_file(created))
          let state =
            State(
              ..state,
              created_folders: dict.insert(
                state.created_folders,
                cache_key,
                created.file_id,
              ),
            )
          Ok(#(state, created.file_id))
        }
      }
    },
  )
}

fn push_file(
  config: TransferConfig,
  plan: UploadPlan,
  parent_id: String,
) -> Result(Nil, String) {
  let source = config.root_dir <> "/" <> plan.local.path
  let target = case plan.existing_file_id {
    Some(file_id) -> upload.UpdateFile(file_id)
    None -> upload.CreateFile(name: plan.name, parent_id: parent_id)
  }
  use uploaded <- result.try(config.upload_to_drive(
    target,
    source,
    plan.local.size,
  ))
  record_known(
    config,
    uploaded.file_id,
    plan.local.path,
    uploaded.modified_time,
    uploaded.md5,
    plan.local.size,
    Blob,
  )
  config.settle_upload(
    plan.local.path,
    Ok(remote_poller.translate_file(uploaded)),
  )
  Ok(Nil)
}

fn settle_upload_or_retry(
  state: State,
  plan: UploadPlan,
  failed_attempts: Int,
  reason: String,
) -> Nil {
  retry_or(
    state,
    failed_attempts,
    fn(attempts) { RetryUpload(plan, attempts) },
    give_up: fn() { state.config.settle_upload(plan.local.path, Error(reason)) },
  )
}

// --- Trash ----------------------------------------------------------------------

fn run_trash(
  state: State,
  file_id: String,
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  case state.config.trash_remote(file_id) {
    Ok(Nil) -> {
      process.send(state.config.state_owner, state_owner.ForgetKnown(file_id))
      state.config.settle_trash(file_id, Ok(Nil))
      actor.continue(state)
    }
    Error(reason) -> {
      retry_or(
        state,
        failed_attempts,
        fn(attempts) { RetryTrash(file_id, attempts) },
        give_up: fn() { state.config.settle_trash(file_id, Error(reason)) },
      )
      actor.continue(state)
    }
  }
}

// --- Shared -------------------------------------------------------------------

fn retry_or(
  state: State,
  failed_attempts: Int,
  build_retry: fn(Int) -> Command,
  give_up give_up: fn() -> Nil,
) -> Nil {
  let next_attempts = failed_attempts + 1
  case next_attempts < max_transfer_attempts {
    True -> {
      let delay = state.config.pick_retry_delay_ms(failed_attempts)
      process.send_after(state.self, delay, build_retry(next_attempts))
      Nil
    }
    False -> give_up()
  }
}

fn record_known(
  config: TransferConfig,
  file_id: String,
  path: String,
  remote_modified_time: String,
  md5: option.Option(String),
  fallback_size: Int,
  kind: entry.FileKind,
) -> Nil {
  let destination = config.root_dir <> "/" <> path
  let #(size, mtime_seconds) = case simplifile.file_info(destination) {
    Ok(info) -> #(info.size, info.mtime_seconds)
    Error(_) -> #(fallback_size, 0)
  }
  process.send(
    config.state_owner,
    state_owner.PutKnown(KnownFile(
      file_id: file_id,
      path: path,
      remote_modified_time: remote_modified_time,
      md5: md5,
      size: size,
      local_mtime_seconds: mtime_seconds,
      kind: kind,
    )),
  )
}

fn describe_error(
  result: Result(a, simplifile.FileError),
) -> Result(a, String) {
  result.map_error(result, simplifile.describe_error)
}
