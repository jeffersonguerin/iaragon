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
import gleam/string
import iaragon/application/state_owner
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

pub type Command {
  /// The full remote snapshot plus the real root id: replaces the model and
  /// runs a reconciliation round.
  SeedMirror(root_id: String, files: List(RemoteSighting))
  /// Deltas from the Changes API: update the model and run a round.
  /// Ignored until a seed has arrived (there is no tree to resolve against).
  ApplyRemoteChanges(observations: List(RemoteObservation))
}

pub type ReconcilerConfig {
  ReconcilerConfig(
    state_owner: Subject(state_owner.Command),
    dispatch_download: fn(RemoteFile) -> Nil,
    dispatch_delete_local: fn(String, String) -> Nil,
    scan_local: fn() -> Result(List(LocalFile), String),
    /// Hash a mirror-relative path on demand (md5, lowercase hex).
    hash_local_file: fn(String) -> Result(String, String),
    native_policy: NativeDocPolicy,
  )
}

type State {
  State(
    config: ReconcilerConfig,
    root_id: Option(String),
    model: Dict(String, RemoteSighting),
  )
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
  actor.new(State(config: config, root_id: None, model: dict.new()))
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
      let state = State(..state, root_id: Some(root_id), model: model)
      run_round(state)
      actor.continue(state)
    }
    ApplyRemoteChanges(observations) ->
      case state.root_id {
        None -> actor.continue(state)
        Some(_root) -> {
          let model = list.fold(observations, state.model, apply_observation)
          let state = State(..state, model: model)
          run_round(state)
          actor.continue(state)
        }
      }
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

fn run_round(state: State) -> Nil {
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

  let locals = hash_never_synced_twins(config, locals, remotes, known_by_path)

  reconcile.reconcile_all(locals, remotes, known)
  |> list.each(fn(decision) {
    case decision {
      decision.DownloadRemote(file_id, _path) ->
        case dict.get(remote_by_id, file_id) {
          Ok(remote) -> config.dispatch_download(remote)
          Error(Nil) -> Nil
        }
      decision.DeleteLocal(path) ->
        case dict.get(known_by_path, path) {
          Ok(file) -> config.dispatch_delete_local(file.file_id, path)
          Error(Nil) -> Nil
        }
      decision.ForgetKnown(file_id) ->
        process.send(config.state_owner, state_owner.ForgetKnown(file_id))
      // Download-only phase: local-driven decisions wait for upload support.
      decision.UploadLocal(_) -> Nil
      decision.DeleteRemote(_) -> Nil
      decision.Conflict(_, _, _) -> Nil
      decision.Noop -> Nil
    }
  })
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
