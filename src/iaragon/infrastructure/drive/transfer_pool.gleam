//// Executes the reconciler's transfer decisions against the local mirror
//// and Drive. Downloads: blobs (streamed via the injected fetch), folders,
//// Google-native materialisation (a `.desktop` link, or a real export under
//// an export policy), shortcuts as links to their target, local deletions.
//// Uploads: resumable pushes (create or update-in-place), remote
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
import iaragon/application/reconciler.{
  type MoveRemotePlan, type RemoteSighting, type UploadPlan,
}
import iaragon/application/state_owner
import iaragon/domain/entry.{
  type NativeDocPolicy, type RemoteFile, Blob, Folder, GoogleNative, KnownFile,
  Shortcut,
}
import iaragon/domain/link_file
import iaragon/domain/native_docs
import iaragon/domain/paths
import iaragon/infrastructure/drive/changes.{type ChangedFile}
import iaragon/infrastructure/drive/remote_poller
import iaragon/infrastructure/drive/upload.{type UploadTarget}
import iaragon/infrastructure/fs/local_trash
import simplifile

pub type Command {
  /// Download/materialise a remote file. `expected` is the known the
  /// decision assumed on disk (None for a brand-new remote): the pool
  /// re-checks a blob's destination against it before overwriting, so a
  /// local edit that landed after the decision is not clobbered (the next
  /// round turns it into a conflict instead).
  EnqueueDownload(remote: RemoteFile, expected: option.Option(entry.KnownFile))
  /// Delete the mirror copy the reconciler decided is gone remotely. Carries
  /// the expected known so the pool can re-verify a blob still matches it
  /// right before deleting — a file edited between the decision and here is
  /// left alone (the next round turns it into an edit-wins conflict).
  EnqueueDeleteLocal(known: entry.KnownFile)
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
  /// Apply a local rename remotely: files.update (name + parent swap),
  /// creating any missing destination folders first — no bytes transferred.
  EnqueueMoveRemote(plan: MoveRemotePlan)
  /// Internal: scheduled retries of failed transfers.
  RetryDownload(
    remote: RemoteFile,
    expected: option.Option(entry.KnownFile),
    failed_attempts: Int,
  )
  RetryUpload(plan: UploadPlan, failed_attempts: Int)
  RetryTrash(file_id: String, failed_attempts: Int)
  RetryConflictCopy(remote: RemoteFile, copy_path: String, failed_attempts: Int)
  RetryMoveRemote(plan: MoveRemotePlan, failed_attempts: Int)
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
    rename_remote: fn(String, String, String, String) ->
      Result(ChangedFile, String),
    /// (file_id, export mime, absolute destination) — native-doc export,
    /// streamed to disk like a blob download.
    export_to_disk: fn(String, String, String) -> Result(Nil, String),
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
    /// (file_id, new_name, add_parent_id, remove_parent_id).
    rename_remote: fn(String, String, String, String) ->
      Result(ChangedFile, String),
    /// (file_id, export mime, absolute destination) — native-doc export.
    export_to_disk: fn(String, String, String) -> Result(Nil, String),
    /// (relative path, status) — user-visible sync-state signal (file
    /// manager emblems). Decoration only: failures never fail a transfer.
    signal_status: fn(String, entry.SyncStatus) -> Nil,
    /// (relative path) — the path ceased to exist locally (deleted, or a
    /// move's old source). Lets the status board drop its entry so a stale
    /// SyncFailed cannot pin the aggregate forever. Decoration only.
    clear_status: fn(String) -> Nil,
    /// Outcome feedback into the reconciler (path / file_id keyed).
    settle_upload: fn(String, Result(RemoteSighting, String)) -> Nil,
    settle_trash: fn(String, Result(Nil, String)) -> Nil,
    settle_conflict: fn(String, Result(Nil, String)) -> Nil,
    settle_move: fn(String, Result(RemoteSighting, String)) -> Nil,
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
    EnqueueDownload(remote, expected) ->
      run_download(state, remote, expected, 0)
    RetryDownload(remote, expected, failed_attempts) ->
      run_download(state, remote, expected, failed_attempts)
    EnqueueDeleteLocal(known) -> {
      run_delete_local(state.config, known)
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
    EnqueueMoveRemote(plan) -> run_move_remote(state, plan, 0)
    RetryMoveRemote(plan, failed_attempts) ->
      run_move_remote(state, plan, failed_attempts)
    EnqueueConflictCopy(remote, copy_path) ->
      run_conflict_copy(state, remote, copy_path, 0)
    RetryConflictCopy(remote, copy_path, failed_attempts) ->
      run_conflict_copy(state, remote, copy_path, failed_attempts)
  }
}

// --- Local deletions --------------------------------------------------------------

/// Delete the local mirror copy, keyed on what kind of thing the known says
/// it is:
///
/// - Folder: only an EMPTY directory is removed (`simplifile.delete` is
///   recursive, and a non-empty dir may hold never-synced bytes); a
///   non-empty one waits for its children's own deletions.
/// - Blob: re-verify the file still matches the known's size+mtime right
///   before deleting. A blob edited between the decision and now no longer
///   matches — skip it and keep the known, so the next round re-decides and
///   the domain turns it into a LocalEditRemoteDelete conflict (edit wins).
/// - Google-native / shortcut: these are `.desktop` links WE generate, not
///   user content, so delete unconditionally (this is also the
///   policy-switch rematerialise path, which must drop the old link).
///
/// Either way delete_file (non-recursive) is used for the file branch, so
/// kind drift can never turn one deletion into a recursive tree wipe.
fn run_delete_local(config: TransferConfig, known: entry.KnownFile) -> Nil {
  let target = config.root_dir <> "/" <> known.path
  let removed = case known.kind {
    Folder ->
      case simplifile.is_directory(target) {
        Ok(True) ->
          case simplifile.read_directory(target) {
            Ok([]) -> {
              let _ = simplifile.delete(target)
              True
            }
            _ -> False
          }
        // Already gone (or never a dir): nothing to remove, converge.
        _ -> True
      }
    Blob ->
      case blob_still_matches(target, known) {
        True ->
          // User content is never unlinked: it moves into the local trash
          // (.iaragon-trash/, retention-swept at boot), so a wrong remote
          // deletion stays recoverable. A failed move keeps the known and
          // the file; the next round re-decides and retries.
          case simplifile.is_file(target) {
            Ok(True) ->
              case local_trash.move_to_trash(config.root_dir, known.path) {
                Ok(Nil) -> True
                Error(_) -> False
              }
            // Already gone: nothing to preserve, converge.
            _ -> True
          }
        False -> False
      }
    GoogleNative | Shortcut(_) -> {
      let _ = simplifile.delete_file(target)
      True
    }
  }
  case removed {
    True -> {
      process.send(config.state_owner, state_owner.ForgetKnown(known.file_id))
      // The path is gone: drop any lingering board entry (a SyncFailed left
      // by an earlier attempt would otherwise pin the aggregate forever).
      config.clear_status(known.path)
    }
    False -> Nil
  }
}

/// A blob is safe to delete only if it still looks like the last-synced
/// state. An absent file is a harmless no-op (converge); a present file
/// whose size or mtime drifted was edited after the decision — protect it.
fn blob_still_matches(target: String, known: entry.KnownFile) -> Bool {
  case simplifile.file_info(target) {
    Ok(info) ->
      info.size == known.size && info.mtime_seconds == known.local_mtime_seconds
    Error(_) -> True
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
      True, False ->
        simplifile.rename(at: source, to: destination) |> describe_error
      // Already carried to its destination (e.g. by a parent folder rename).
      False, True -> Ok(Nil)
      False, False -> Error("neither source nor destination exists")
      // Both exist. An EMPTY source directory means the children were
      // already carried into the pre-existing destination one by one: clear
      // the leftover and count the move as done. Anything with content is
      // suspicious — leave the filesystem alone and let the next round
      // reconcile the difference.
      True, True ->
        case simplifile.read_directory(source) {
          Ok([]) -> simplifile.delete(source) |> describe_error
          _ -> Error("destination already occupied")
        }
    }
  }
  case moved {
    Ok(Nil) -> {
      process.send(config.state_owner, state_owner.PutKnown(updated))
      // The old source path no longer exists — drop its board entry.
      config.clear_status(from)
      // A plain rename drops gvfs metadata: repaint the destination.
      config.signal_status(updated.path, entry.Synced)
    }
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

// --- Remote moves (local renames) -------------------------------------------------

fn run_move_remote(
  state: State,
  plan: MoveRemotePlan,
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  case
    ensure_remote_folders_for(
      state,
      plan.anchor_parent_id,
      plan.missing_folders,
    )
  {
    Ok(#(state, parent_id)) ->
      case
        state.config.rename_remote(
          plan.file_id,
          plan.new_name,
          parent_id,
          plan.old_parent_id,
        )
      {
        Ok(renamed) -> {
          record_known(
            state.config,
            renamed.file_id,
            plan.to_path,
            renamed.modified_time,
            renamed.md5,
            plan.local.size,
            Blob,
          )
          state.config.settle_move(
            plan.file_id,
            Ok(remote_poller.translate_file(renamed)),
          )
          actor.continue(state)
        }
        Error(reason) -> {
          settle_move_or_retry(state, plan, failed_attempts, reason)
          actor.continue(state)
        }
      }
    Error(reason) -> {
      settle_move_or_retry(state, plan, failed_attempts, reason)
      actor.continue(state)
    }
  }
}

fn settle_move_or_retry(
  state: State,
  plan: MoveRemotePlan,
  failed_attempts: Int,
  reason: String,
) -> Nil {
  retry_or(
    state,
    failed_attempts,
    fn(attempts) { RetryMoveRemote(plan, attempts) },
    give_up: fn() {
      state.config.signal_status(plan.to_path, entry.SyncFailed)
      state.config.settle_move(plan.file_id, Error(reason))
    },
  )
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
          state.config.signal_status(remote.path, entry.SyncFailed)
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
  expected: option.Option(entry.KnownFile),
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  // Protect a blob whose local copy changed since the decision: overwriting
  // it would silently lose the edit (the domain would have made it a
  // conflict). Skip and let the next round re-decide. (Folders, native
  // links and shortcuts are not user content, and natives are download-only
  // by policy, so they are always (re)materialised.)
  case remote.kind, safe_to_overwrite(state.config, remote.path, expected) {
    Blob, False -> actor.continue(state)
    _, _ -> {
      state.config.signal_status(remote.path, entry.Syncing)
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
            fn(attempts) { RetryDownload(remote, expected, attempts) },
            give_up: fn() {
              state.config.signal_status(remote.path, entry.SyncFailed)
            },
          )
          actor.continue(state)
        }
      }
    }
  }
}

/// A changed-remote download is unsafe only if the destination blob no
/// longer matches the last-synced bytes the decision assumed (Some(known)):
/// a size/mtime drift is a local edit that must not be clobbered. A
/// brand-new remote (None) carries no expectation to check — overwriting an
/// existing same-path file is left to the next round's both-created
/// handling, and guarding it here would wrongly skip an idempotent
/// re-download of a file already written but not yet recorded.
fn safe_to_overwrite(
  config: TransferConfig,
  path: String,
  expected: option.Option(entry.KnownFile),
) -> Bool {
  case expected {
    option.None -> True
    option.Some(known) ->
      case simplifile.file_info(config.root_dir <> "/" <> path) {
        Error(_) -> True
        Ok(info) ->
          info.size == known.size
          && info.mtime_seconds == known.local_mtime_seconds
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
    GoogleNative ->
      case
        native_docs.choose_materialisation(
          remote.mime_type,
          config.native_policy,
          size: remote.size,
        )
      {
        native_docs.WriteLinkFile ->
          write_link_file(destination, remote.name, remote.file_id)
        native_docs.ExportDocument(export_mime, _extension) ->
          config.export_to_disk(remote.file_id, export_mime, destination)
      }
    Shortcut(target_id) -> write_link_file(destination, remote.name, target_id)
  }
}

fn write_link_file(
  destination: String,
  name: String,
  target_id: String,
) -> Result(Nil, String) {
  // The name and target id are untrusted Drive metadata; link_file.build
  // escapes them so a crafted name cannot inject Desktop Entry keys.
  simplifile.write(to: destination, contents: link_file.build(name, target_id))
  |> describe_error
}

fn record_downloaded(config: TransferConfig, remote: RemoteFile) -> Nil {
  // Edit-vs-record race: the user can touch the file in the instant between
  // the download's rename and this record. Recording then would mark the
  // EDITED bytes as "synced" (remote md5 + edited size/mtime), so the edit
  // never uploads and the next remote change silently overwrites it. For a
  // blob whose remote size is known, a size mismatch on disk means exactly
  // that — skip recording; with no known entry, the next round sees
  // both-created and preserves the edit as a conflict copy.
  let user_touched = case remote.kind, remote.size {
    Blob, option.Some(expected_size) ->
      case simplifile.file_info(config.root_dir <> "/" <> remote.path) {
        Ok(info) -> info.size != expected_size
        Error(_) -> False
      }
    _, _ -> False
  }
  case user_touched {
    True -> Nil
    False ->
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
}

// --- Uploads ------------------------------------------------------------------

fn run_upload(
  state: State,
  plan: UploadPlan,
  failed_attempts: Int,
) -> actor.Next(State, Command) {
  state.config.signal_status(plan.local.path, entry.Syncing)
  case
    ensure_remote_folders_for(
      state,
      plan.anchor_parent_id,
      plan.missing_folders,
    )
  {
    Ok(#(state, parent_id)) ->
      case push_file(state.config, plan, parent_id) {
        Ok(Nil) -> actor.continue(state)
        Error(reason) -> {
          settle_upload_or_retry(state, plan, failed_attempts, reason)
          actor.continue(drop_created_folders(state))
        }
      }
    Error(reason) -> {
      settle_upload_or_retry(state, plan, failed_attempts, reason)
      actor.continue(drop_created_folders(state))
    }
  }
}

/// Any upload error empties the created-folders cache. A cached id can be
/// the very cause of the failure — the folder was deleted remotely and the
/// live model no longer lists it, so every retry would 404 against the dead
/// id until the daemon restarts. Dropping the whole cache is safe (folders
/// are re-created or re-observed on demand) and only costs a little churn
/// on genuinely transient errors.
fn drop_created_folders(state: State) -> State {
  State(..state, created_folders: dict.new())
}

/// Create the plan's missing folder chain (outermost first), reusing ids of
/// folders this pool already created. Returns the final parent id.
fn ensure_remote_folders_for(
  state: State,
  anchor_parent_id: String,
  missing_folders: List(String),
) -> Result(#(State, String), String) {
  list.try_fold(
    missing_folders,
    #(state, anchor_parent_id),
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
  // Record the metadata captured at scan time, NOT a fresh stat: if the user
  // edited the file mid-upload (Drive then holds torn bytes), the real file
  // is now newer than this recorded mtime, so the next round detects a local
  // change and re-uploads — self-healing — instead of freezing the corrupt
  // remote as "synced" and never revisiting it.
  process.send(
    config.state_owner,
    state_owner.PutKnown(KnownFile(
      file_id: uploaded.file_id,
      path: plan.local.path,
      remote_modified_time: uploaded.modified_time,
      md5: uploaded.md5,
      size: plan.local.size,
      local_mtime_seconds: plan.local.mtime_seconds,
      kind: Blob,
    )),
  )
  config.signal_status(plan.local.path, entry.Synced)
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
    give_up: fn() {
      state.config.signal_status(plan.local.path, entry.SyncFailed)
      state.config.settle_upload(plan.local.path, Error(reason))
    },
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
  // The record IS what makes the file synced — paint it in the same breath.
  config.signal_status(path, entry.Synced)
}

fn describe_error(
  result: Result(a, simplifile.FileError),
) -> Result(a, String) {
  result.map_error(result, simplifile.describe_error)
}
