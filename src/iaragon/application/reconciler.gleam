//// Orchestrates sync rounds. Holds the remote model — seeded once from the
//// initial listing, kept fresh by change observations — and on every intake:
//// resolves POSIX paths (pure), scans the local mirror, loads the known
//// state, hashes local twins on demand, runs the pure three-way
//// reconciliation and dispatches the download-only decisions through
//// injected functions (the transfer pool, in production).
////
//// Intake types are defined HERE: application owns its contracts, and the
//// infrastructure (poller) maps the Drive wire format onto them. Upload-side
//// decisions (UploadLocal, DeleteRemote, Conflict) are consciously ignored
//// until the upload phase.
////
//// Known limitation (documented): the model lives in memory; if this actor
//// crashes, changes are ignored until a new seed arrives (daemon restart).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/set.{type Set}
import gleam/string
import iaragon/application/state_owner
import iaragon/domain/conflicts
import iaragon/domain/decision
import iaragon/domain/entry.{
  type LocalFile, type NativeDocPolicy, type RemoteFile, Blob, Folder,
  GoogleNative, LocalFile, RemoteFile,
}
import iaragon/domain/paths
import iaragon/domain/reconcile

/// A remote file as observed on the wire, before path resolution. This is an
/// application contract: the poller maps Drive types onto it.
pub type RemoteSighting {
  RemoteSighting(
    file_id: String,
    name: String,
    mime_type: String,
    parent_id: Option(String),
    modified_time: String,
    size: Option(Int),
    md5: Option(String),
    trashed: Bool,
  )
}

pub type RemoteObservation {
  ObservedFile(file: RemoteSighting)
  ObservedRemoval(file_id: String)
}

/// Everything the transfer side needs to put one local file on Drive:
/// which bytes, under which name, whether it updates an existing file, and
/// where it hangs — the deepest ALREADY-EXISTING remote folder plus the
/// chain of folder names still to be created under it, outermost first.
pub type UploadPlan {
  UploadPlan(
    local: LocalFile,
    name: String,
    existing_file_id: Option(String),
    anchor_parent_id: String,
    missing_folders: List(String),
  )
}

pub type Command {
  /// The full remote snapshot plus the real root id: replaces the model and
  /// runs a reconciliation round.
  SeedMirror(root_id: String, files: List(RemoteSighting))
  /// Deltas from the Changes API: update the model and run a round.
  /// Ignored until a seed has arrived (there is no tree to resolve against).
  ApplyRemoteChanges(observations: List(RemoteObservation))
  /// Outcome of a dispatched upload, reported by the transfer side. Success
  /// puts the uploaded file straight into the remote model — waiting for the
  /// next Changes poll would leave a window where the file looks
  /// remote-absent and gets wrongly deleted locally.
  SettleUpload(path: String, outcome: Result(RemoteSighting, String))
  /// Outcome of a dispatched remote trash.
  SettleTrash(file_id: String, outcome: Result(Nil, String))
  /// Outcome of a dispatched conflicted-copy resolution (path keyed). The
  /// moved-aside copy surfaces in the next scan and uploads as a new file.
  SettleConflict(path: String, outcome: Result(Nil, String))
  /// Run a round without new remote input — local edits have no other
  /// trigger until a filesystem watcher lands.
  ReconcileNow
}

pub type ReconcilerConfig {
  ReconcilerConfig(
    state_owner: Subject(state_owner.Command),
    dispatch_download: fn(RemoteFile) -> Nil,
    dispatch_delete_local: fn(String, String) -> Nil,
    dispatch_upload: fn(UploadPlan) -> Nil,
    dispatch_trash_remote: fn(String) -> Nil,
    /// Edit-edit resolution: (remote version, conflicted-copy path).
    dispatch_conflict_copy: fn(RemoteFile, String) -> Nil,
    scan_local: fn() -> Result(List(LocalFile), String),
    /// Hash a mirror-relative path on demand (md5, lowercase hex).
    hash_local_file: fn(String) -> Result(String, String),
    native_policy: NativeDocPolicy,
    /// Rounds re-run on this interval once the mirror is seeded — the local
    /// backstop behind the watcher.
    round_interval_ms: Int,
    /// Date stamp (YYYY-MM-DD) for conflicted-copy names; injected for tests.
    today: fn() -> String,
  )
}

type State {
  State(
    config: ReconcilerConfig,
    self: Subject(Command),
    root_id: Option(String),
    model: Dict(String, RemoteSighting),
    /// Paths with an upload or conflict resolution in flight and file ids
    /// with a trash in flight: never re-dispatched until settled.
    pending_uploads: Set(String),
    pending_trashes: Set(String),
    pending_conflicts: Set(String),
  )
}

fn forget_pending_upload(state: State, path: String) -> State {
  State(..state, pending_uploads: set.delete(state.pending_uploads, path))
}

fn forget_pending_trash(state: State, file_id: String) -> State {
  State(..state, pending_trashes: set.delete(state.pending_trashes, file_id))
}

pub fn supervised(
  name: Name(Command),
  config: ReconcilerConfig,
) -> ChildSpecification(Subject(Command)) {
  supervision.worker(fn() { start(name, config) })
}

pub fn start(
  name: Name(Command),
  config: ReconcilerConfig,
) -> actor.StartResult(Subject(Command)) {
  actor.new(State(
    config: config,
    self: process.named_subject(name),
    root_id: None,
    model: dict.new(),
    pending_uploads: set.new(),
    pending_trashes: set.new(),
    pending_conflicts: set.new(),
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
    SeedMirror(root_id, files) -> {
      let model =
        files
        |> list.filter(fn(sighting) { !sighting.trashed })
        |> list.map(fn(sighting) { #(sighting.file_id, sighting) })
        |> dict.from_list
      // Arm the periodic timer exactly once (each ReconcileNow re-arms it);
      // a re-seed after a poller restart must not add a second timer chain.
      case state.root_id {
        None -> {
          let _ =
            process.send_after(
              state.self,
              state.config.round_interval_ms,
              ReconcileNow,
            )
          Nil
        }
        Some(_already_seeded) -> Nil
      }
      let state = State(..state, root_id: Some(root_id), model: model)
      actor.continue(run_round(state))
    }
    ApplyRemoteChanges(observations) ->
      case state.root_id {
        None -> actor.continue(state)
        Some(_root) -> {
          let model = list.fold(observations, state.model, apply_observation)
          actor.continue(run_round(State(..state, model: model)))
        }
      }
    SettleUpload(path, outcome) -> {
      let state = case outcome {
        Ok(sighting) ->
          State(
            ..state,
            model: dict.insert(state.model, sighting.file_id, sighting),
          )
        Error(_reason) -> state
      }
      let state = forget_pending_upload(state, path)
      actor.continue(run_round_if_seeded(state))
    }
    SettleTrash(file_id, outcome) -> {
      let state = case outcome {
        Ok(Nil) -> State(..state, model: dict.delete(state.model, file_id))
        Error(_reason) -> state
      }
      let state = forget_pending_trash(state, file_id)
      actor.continue(run_round_if_seeded(state))
    }
    SettleConflict(path, _outcome) -> {
      let state =
        State(
          ..state,
          pending_conflicts: set.delete(state.pending_conflicts, path),
        )
      actor.continue(run_round_if_seeded(state))
    }
    ReconcileNow -> {
      process.send_after(
        state.self,
        state.config.round_interval_ms,
        ReconcileNow,
      )
      actor.continue(run_round_if_seeded(state))
    }
  }
}

fn run_round_if_seeded(state: State) -> State {
  case state.root_id {
    Some(_root) -> run_round(state)
    None -> state
  }
}

fn apply_observation(
  model: Dict(String, RemoteSighting),
  observation: RemoteObservation,
) -> Dict(String, RemoteSighting) {
  case observation {
    ObservedRemoval(file_id) -> dict.delete(model, file_id)
    ObservedFile(sighting) ->
      case sighting.trashed {
        True -> dict.delete(model, sighting.file_id)
        False -> dict.insert(model, sighting.file_id, sighting)
      }
  }
}

fn run_round(state: State) -> State {
  let config = state.config
  let assert Some(root_id) = state.root_id
  let assert Ok(locals) = config.scan_local()
  let known = process.call(config.state_owner, 5000, state_owner.ListKnown)

  let remotes = plan_remote_files(state.model, root_id, config.native_policy)
  let remote_by_id =
    remotes
    |> list.map(fn(remote) { #(remote.file_id, remote) })
    |> dict.from_list
  let known_by_path =
    known
    |> list.map(fn(file) { #(file.path, file) })
    |> dict.from_list
  let folder_ids_by_path =
    remotes
    |> list.filter(fn(remote) { remote.kind == Folder })
    |> list.map(fn(remote) { #(remote.path, remote.file_id) })
    |> dict.from_list

  let locals = hash_never_synced_twins(config, locals, remotes, known_by_path)
  let locals_by_path =
    locals
    |> list.map(fn(local) { #(local.path, local) })
    |> dict.from_list

  reconcile.reconcile_all(locals, remotes, known)
  |> list.fold(state, fn(state, decision) {
    case decision {
      decision.DownloadRemote(file_id, _path) -> {
        case dict.get(remote_by_id, file_id) {
          Ok(remote) -> config.dispatch_download(remote)
          Error(Nil) -> Nil
        }
        state
      }
      decision.DeleteLocal(path) -> {
        case dict.get(known_by_path, path) {
          Ok(file) -> config.dispatch_delete_local(file.file_id, path)
          Error(Nil) -> Nil
        }
        state
      }
      decision.ForgetKnown(file_id) -> {
        process.send(config.state_owner, state_owner.ForgetKnown(file_id))
        state
      }
      decision.UploadLocal(path) ->
        dispatch_upload_once(
          state,
          path,
          locals_by_path,
          known_by_path,
          folder_ids_by_path,
          root_id,
        )
      decision.DeleteRemote(file_id) ->
        case set.contains(state.pending_trashes, file_id) {
          True -> state
          False -> {
            config.dispatch_trash_remote(file_id)
            State(
              ..state,
              pending_trashes: set.insert(state.pending_trashes, file_id),
            )
          }
        }
      decision.Conflict(path, file_id, kind) ->
        resolve_conflict(state, path, file_id, kind, remote_by_id)
      decision.Noop -> state
    }
  })
}

/// The chosen policies: edit-edit (and divergent both-created) becomes a
/// dated conflicted copy — local moves aside and syncs up as a new file,
/// remote takes the original path. Edit-versus-delete: the EDIT wins — the
/// stale sync link is forgotten, so the surviving side re-creates the file
/// as brand new on the next round.
fn resolve_conflict(
  state: State,
  path: String,
  file_id: String,
  kind: decision.ConflictKind,
  remote_by_id: Dict(String, RemoteFile),
) -> State {
  case kind {
    decision.EditEdit | decision.BothCreated ->
      case
        set.contains(state.pending_conflicts, path),
        dict.get(remote_by_id, file_id)
      {
        False, Ok(remote) -> {
          state.config.dispatch_conflict_copy(
            remote,
            conflicts.build_conflicted_copy_path(path, state.config.today()),
          )
          State(
            ..state,
            pending_conflicts: set.insert(state.pending_conflicts, path),
          )
        }
        _, _ -> state
      }
    decision.LocalEditRemoteDelete | decision.RemoteEditLocalDelete -> {
      process.send(state.config.state_owner, state_owner.ForgetKnown(file_id))
      state
    }
  }
}

fn dispatch_upload_once(
  state: State,
  path: String,
  locals_by_path: Dict(String, LocalFile),
  known_by_path: Dict(String, entry.KnownFile),
  folder_ids_by_path: Dict(String, String),
  root_id: String,
) -> State {
  let already_in_flight = set.contains(state.pending_uploads, path)
  case already_in_flight, dict.get(locals_by_path, path) {
    True, _ -> state
    False, Error(Nil) -> state
    False, Ok(local) -> {
      let #(directory_segments, name) = split_file_name(path)
      let #(anchor_parent_id, missing_folders) =
        resolve_upload_anchor(directory_segments, folder_ids_by_path, root_id)
      state.config.dispatch_upload(UploadPlan(
        local: local,
        name: name,
        existing_file_id: case dict.get(known_by_path, path) {
          Ok(known) -> Some(known.file_id)
          Error(Nil) -> None
        },
        anchor_parent_id: anchor_parent_id,
        missing_folders: missing_folders,
      ))
      State(..state, pending_uploads: set.insert(state.pending_uploads, path))
    }
  }
}

fn split_file_name(path: String) -> #(List(String), String) {
  let segments = string.split(path, "/")
  case list.reverse(segments) {
    [name, ..reversed_directory] -> #(list.reverse(reversed_directory), name)
    [] -> #([], path)
  }
}

/// Find the deepest directory prefix that already exists as a remote folder;
/// everything below it must be created, outermost first.
fn resolve_upload_anchor(
  directory_segments: List(String),
  folder_ids_by_path: Dict(String, String),
  root_id: String,
) -> #(String, List(String)) {
  case directory_segments {
    [] -> #(root_id, [])
    segments ->
      case dict.get(folder_ids_by_path, string.join(segments, "/")) {
        Ok(folder_id) -> #(folder_id, [])
        Error(Nil) -> {
          let #(kept, missing_tail) = split_off_deepest(segments)
          let #(anchor, missing) =
            resolve_upload_anchor(kept, folder_ids_by_path, root_id)
          #(anchor, list.append(missing, [missing_tail]))
        }
      }
  }
}

fn split_off_deepest(segments: List(String)) -> #(List(String), String) {
  case list.reverse(segments) {
    [deepest, ..reversed_kept] -> #(list.reverse(reversed_kept), deepest)
    [] -> #([], "")
  }
}

/// Turn the sighting model into placeable RemoteFiles: resolve paths from the
/// parent tree and give materialised natives their link-file suffix.
fn plan_remote_files(
  model: Dict(String, RemoteSighting),
  root_id: String,
  _policy: NativeDocPolicy,
) -> List(RemoteFile) {
  let sightings = dict.values(model)
  let nodes =
    sightings
    |> list.filter_map(fn(sighting) {
      case classify_mime(sighting.mime_type) {
        // Shortcuts need a shortcutDetails fetch to be materialised; they
        // are excluded from the mirror for now.
        None -> Error(Nil)
        Some(kind) ->
          Ok(paths.RemoteNode(
            file_id: sighting.file_id,
            name: sighting.name,
            parent_id: sighting.parent_id,
            is_folder: kind == Folder,
          ))
      }
    })
  let resolved = paths.resolve_paths(nodes, root_id)

  list.filter_map(sightings, fn(sighting) {
    case
      classify_mime(sighting.mime_type),
      dict.get(resolved, sighting.file_id)
    {
      Some(kind), Ok(path) ->
        Ok(RemoteFile(
          file_id: sighting.file_id,
          name: sighting.name,
          path: materialized_path(path, kind),
          mime_type: sighting.mime_type,
          parent_id: sighting.parent_id,
          modified_time: sighting.modified_time,
          size: sighting.size,
          md5: sighting.md5,
          trashed: sighting.trashed,
          kind: kind,
        ))
      _, _ -> Error(Nil)
    }
  })
}

fn materialized_path(path: String, kind: entry.FileKind) -> String {
  case kind {
    // Every native policy materialises as a link for now; exports land with
    // the upload-phase FFI.
    GoogleNative -> path <> ".desktop"
    _ -> path
  }
}

fn classify_mime(mime_type: String) -> Option(entry.FileKind) {
  case mime_type {
    "application/vnd.google-apps.folder" -> Some(Folder)
    "application/vnd.google-apps.shortcut" -> None
    _ ->
      case string.starts_with(mime_type, "application/vnd.google-apps.") {
        True -> Some(GoogleNative)
        False -> Some(Blob)
      }
  }
}

/// A local file sitting where a never-synced remote lands can only be told
/// apart from a conflict by its checksum: hash exactly those, on demand.
fn hash_never_synced_twins(
  config: ReconcilerConfig,
  locals: List(LocalFile),
  remotes: List(RemoteFile),
  known_by_path: Dict(String, entry.KnownFile),
) -> List(LocalFile) {
  let never_synced_remote_paths =
    remotes
    |> list.filter(fn(remote) { !dict.has_key(known_by_path, remote.path) })
    |> list.map(fn(remote) { remote.path })
    |> list.fold(dict.new(), fn(acc, path) { dict.insert(acc, path, Nil) })

  list.map(locals, fn(local) {
    let is_twin =
      dict.has_key(never_synced_remote_paths, local.path) && local.md5 == None
    case is_twin {
      False -> local
      True ->
        case config.hash_local_file(local.path) {
          Ok(md5) -> LocalFile(..local, md5: Some(md5))
          // Unhashable stays checksum-less: reconcile conservatively
          // conflicts, and download-only skips conflicts — nothing is lost.
          Error(_) -> local
        }
    }
  })
}
