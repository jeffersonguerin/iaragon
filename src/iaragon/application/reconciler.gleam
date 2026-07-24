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
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import iaragon/application/state_owner
import iaragon/domain/conflicts
import iaragon/domain/decision
import iaragon/domain/entry.{
  type LocalFile, type NativeDocPolicy, type RemoteFile, Blob, Folder,
  GoogleNative, LocalFile, RemoteFile,
}
import iaragon/domain/native_docs
import iaragon/domain/paths
import iaragon/domain/reconcile
import iaragon/domain/safety

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
    /// Only shortcuts carry one: the file the shortcut points at.
    shortcut_target_id: Option(String),
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

/// Everything the transfer side needs to rename/move one remote file to
/// match a local rename: identity, the new name, the parent swap, and the
/// folder chain still to be created (like uploads).
pub type MoveRemotePlan {
  MoveRemotePlan(
    file_id: String,
    from_path: String,
    to_path: String,
    new_name: String,
    old_parent_id: String,
    anchor_parent_id: String,
    missing_folders: List(String),
    local: LocalFile,
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
  /// Outcome of a dispatched remote move (file_id keyed). Success carries
  /// the renamed sighting straight into the model.
  SettleMove(file_id: String, outcome: Result(RemoteSighting, String))
  /// Run a round without new remote input — local edits have no other
  /// trigger until a filesystem watcher lands. Never re-arms the periodic
  /// timer: the watcher sends one of these per activity burst, and each
  /// re-arm would spawn one more everlasting timer chain.
  ReconcileNow
  /// The periodic timer chain. The generation must match the one this
  /// incarnation armed: a tick from a PREVIOUS incarnation's chain (timers
  /// on the actor's NAME survive its crash) is dropped without re-arming,
  /// so crashes cannot multiply chains.
  TickRound(generation: Int)
  /// The monitored transfer pool went down (delivered by its monitor). Any
  /// upload/trash/move THAT POOL was carrying will never settle, so pending
  /// guards tagged with its pid must be dropped — otherwise those paths/ids
  /// would stop syncing until this actor itself restarts. Guards tagged
  /// with a DIFFERENT pid were dispatched to the already-restarted pool
  /// (its Down is merely late in the mailbox) and stay: clearing them would
  /// re-dispatch a live transfer and duplicate the file remotely.
  ForgetInFlight(died: Option(process.Pid))
}

pub type ReconcilerConfig {
  ReconcilerConfig(
    state_owner: Subject(state_owner.Command),
    /// Download a remote file: the second arg is the known the decision
    /// assumed on disk (None for a brand-new remote), so the pool can avoid
    /// clobbering a local edit that landed after the decision.
    dispatch_download: fn(RemoteFile, Option(entry.KnownFile)) -> Nil,
    /// Delete a local mirror copy: the known is passed so the pool can
    /// re-verify the file before deleting (edit-after-decision protection).
    dispatch_delete_local: fn(entry.KnownFile) -> Nil,
    dispatch_upload: fn(UploadPlan) -> Nil,
    dispatch_trash_remote: fn(String) -> Nil,
    /// Edit-edit resolution: (remote version, conflicted-copy path).
    dispatch_conflict_copy: fn(RemoteFile, String) -> Nil,
    /// Remote rename: (known snapshot with the NEW path, old path).
    dispatch_move_local: fn(entry.KnownFile, String) -> Nil,
    /// Local rename: rename the remote file instead of re-uploading.
    dispatch_move_remote: fn(MoveRemotePlan) -> Nil,
    /// Ask the poller for a fresh seed — used when observations arrive but
    /// the in-memory model is gone (this actor was restarted).
    request_seed: fn() -> Nil,
    /// Resolve the transfer pool's current pid so this actor can monitor it.
    /// Error while the pool is (re)starting; the monitor is retried on the
    /// next message. In production this is `subject_owner` of the pool's name.
    resolve_pool_pid: fn() -> Result(process.Pid, Nil),
    scan_local: fn() -> Result(List(LocalFile), String),
    /// Hash a mirror-relative path on demand (md5, lowercase hex).
    hash_local_file: fn(String) -> Result(String, String),
    native_policy: NativeDocPolicy,
    /// Rounds re-run on this interval once the mirror is seeded — the local
    /// backstop behind the watcher.
    round_interval_ms: Int,
    /// Date stamp (YYYY-MM-DD) for conflicted-copy names; injected for tests.
    today: fn() -> String,
    /// One line when something structurally wrong starts (mass-deletion
    /// valve, failed scan) and stays quiet for the rest of the streak —
    /// same journal discipline as the poller's report_trouble.
    report_trouble: fn(String) -> Nil,
    /// One line per round that decided work — per-category counts from
    /// `decision.describe_workload`; workless rounds stay silent. The
    /// journal-side audit trail of what the daemon chose to do, so a round
    /// that forgets or deletes in bulk is explainable after the fact.
    report_activity: fn(String) -> Nil,
    /// The explicit override for the mass-deletion valve (the composition
    /// reads IARAGON_ALLOW_MASS_DELETE=1). Off by default: a round that
    /// wants to delete most of the synced files is treated as an unmounted
    /// mirror / empty listing, not as intent.
    allow_mass_deletion: Bool,
  )
}

type State {
  State(
    config: ReconcilerConfig,
    self: Subject(Command),
    root_id: Option(String),
    model: Dict(String, RemoteSighting),
    /// Paths with an upload or conflict resolution in flight and file ids
    /// with a trash in flight: never re-dispatched until settled. A remote
    /// move holds both keys (its file_id and its destination path), tracked
    /// in pending_move_paths for the settle to clear.
    /// Every pending guard is tagged with the pool pid it was dispatched to
    /// (resolved at dispatch time), so a pool crash clears exactly the
    /// entries that died with it — see `ForgetInFlight`.
    pending_uploads: Dict(String, Option(process.Pid)),
    pending_trashes: Dict(String, Option(process.Pid)),
    pending_conflicts: Dict(String, Option(process.Pid)),
    pending_move_paths: Dict(String, String),
    /// The live monitor on the transfer pool, if one is established. `None`
    /// before the pool is first seen and after it goes down (re-established
    /// on the next message via `ensure_pool_monitored`).
    pool_monitor: Option(process.Monitor),
    /// Identifies THIS incarnation's periodic timer chain; ticks carrying
    /// any other generation are stale chains from before a crash.
    timer_generation: Int,
    /// Streak flags for report_trouble: the first suppressed/failed round
    /// reports, the rest of the streak stays quiet, and a healthy round
    /// resets them.
    warned_mass_deletion: Bool,
    warned_scan: Bool,
  )
}

fn forget_pending_upload(state: State, path: String) -> State {
  State(..state, pending_uploads: dict.delete(state.pending_uploads, path))
}

fn forget_pending_trash(state: State, file_id: String) -> State {
  State(..state, pending_trashes: dict.delete(state.pending_trashes, file_id))
}

/// The pid tag a dispatch records: whichever pool pid is registered right
/// now. `None` while the pool is mid-restart — treated as "unknown pool" and
/// cleared on any pool Down.
fn current_pool_tag(state: State) -> Option(process.Pid) {
  state.config.resolve_pool_pid() |> option.from_result
}

/// Drop the entries whose tag matches the dead pool (or whose pool was
/// unknown at dispatch time). `None` for the dead pid means the Down carried
/// no pid (never for a process monitor) — clear everything, the safe reading.
fn drop_dead_entries(
  entries: Dict(k, Option(process.Pid)),
  died: Option(process.Pid),
) -> Dict(k, Option(process.Pid)) {
  case died {
    None -> dict.new()
    Some(dead_pid) ->
      dict.filter(entries, fn(_key, tag) {
        case tag {
          Some(tag_pid) -> tag_pid != dead_pid
          None -> False
        }
      })
  }
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
  actor.new_with_initialiser(1000, fn(subject) {
    // A catch-all monitor selector installed once: every pool monitor this
    // actor sets up later delivers its Down through here as ForgetInFlight.
    // The default subject must be re-selected explicitly — a custom selector
    // replaces the built-in one.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid: pid, ..) -> ForgetInFlight(Some(pid))
          _other -> ForgetInFlight(None)
        }
      })
    actor.initialised(State(
      config: config,
      self: process.named_subject(name),
      root_id: None,
      model: dict.new(),
      pending_uploads: dict.new(),
      pending_trashes: dict.new(),
      pending_conflicts: dict.new(),
      pending_move_paths: dict.new(),
      pool_monitor: None,
      // Random per incarnation, so a stale chain armed before a crash can
      // never match by accident.
      timer_generation: int.random(1_000_000_000),
      warned_mass_deletion: False,
      warned_scan: False,
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_command)
  |> actor.named(name)
  |> actor.start
}

fn handle_command(
  state: State,
  command: Command,
) -> actor.Next(State, Command) {
  let state = ensure_pool_monitored(state)
  case command {
    SeedMirror(root_id, files) -> {
      let model =
        files
        |> list.filter(fn(sighting) { !sighting.trashed })
        |> list.map(fn(sighting) { #(sighting.file_id, sighting) })
        |> dict.from_list
      // Arm the periodic timer exactly once per incarnation (each matching
      // TickRound re-arms it); a re-seed after a poller restart must not add
      // a second chain, and stale chains die by generation mismatch.
      case state.root_id {
        None -> {
          let _ =
            process.send_after(
              state.self,
              state.config.round_interval_ms,
              TickRound(state.timer_generation),
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
        None -> {
          state.config.request_seed()
          actor.continue(state)
        }
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
          pending_conflicts: dict.delete(state.pending_conflicts, path),
        )
      actor.continue(run_round_if_seeded(state))
    }
    SettleMove(file_id, outcome) -> {
      let state = case outcome {
        Ok(sighting) ->
          State(
            ..state,
            model: dict.insert(state.model, sighting.file_id, sighting),
          )
        Error(_reason) -> state
      }
      // A move holds both pending keys (the vanished id and the new path).
      let state = forget_pending_trash(state, file_id)
      let state = case dict.get(state.pending_move_paths, file_id) {
        Ok(path) ->
          State(
            ..forget_pending_upload(state, path),
            pending_move_paths: dict.delete(state.pending_move_paths, file_id),
          )
        Error(Nil) -> state
      }
      actor.continue(run_round_if_seeded(state))
    }
    // Watcher-triggered: run a round, arm nothing (see the Command doc).
    ReconcileNow -> actor.continue(run_round_if_seeded(state))
    TickRound(generation) ->
      case generation == state.timer_generation {
        True -> {
          process.send_after(
            state.self,
            state.config.round_interval_ms,
            TickRound(generation),
          )
          actor.continue(run_round_if_seeded(state))
        }
        // A chain armed by a previous incarnation (timers on the actor's
        // NAME outlive its crash): dropping it without re-arming is what
        // keeps the chain count at exactly one.
        False -> actor.continue(state)
      }
    ForgetInFlight(died) -> {
      // A pool crashed: whatever THAT pool was carrying is not in flight any
      // more, so clear the guards tagged with its pid and forget the (now
      // dead) monitor. Entries tagged with a different pid were dispatched
      // to the already-restarted pool — its Down is merely late in this
      // mailbox — and must survive, or the next round would re-dispatch a
      // live transfer and duplicate the file remotely. No round is run here;
      // re-dispatch is handled by the next round (the periodic backstop, at
      // latest).
      let pending_trashes = drop_dead_entries(state.pending_trashes, died)
      actor.continue(
        State(
          ..state,
          pending_uploads: drop_dead_entries(state.pending_uploads, died),
          pending_trashes: pending_trashes,
          pending_conflicts: drop_dead_entries(state.pending_conflicts, died),
          // A move holds its path mapping keyed by the same file_id as its
          // trash guard: keep the mapping only while the guard survives.
          pending_move_paths: dict.filter(
            state.pending_move_paths,
            fn(file_id, _path) { dict.has_key(pending_trashes, file_id) },
          ),
          pool_monitor: None,
        ),
      )
    }
  }
}

/// Keep a live monitor on the transfer pool whenever it is resolvable. Cheap
/// and idempotent: once a monitor exists it is left alone (its Down clears it),
/// and while the pool is (re)starting the resolver errors and the monitor is
/// retried on the next message.
fn ensure_pool_monitored(state: State) -> State {
  case state.pool_monitor {
    Some(_already_monitoring) -> state
    None ->
      case state.config.resolve_pool_pid() {
        Ok(pid) -> State(..state, pool_monitor: Some(process.monitor(pid)))
        Error(Nil) -> state
      }
  }
}

fn run_round_if_seeded(state: State) -> State {
  case state.root_id {
    Some(_root) -> run_round(state)
    // Restarted with no model: a local trigger (watcher ReconcileNow) or a
    // stale settle has nothing to reconcile against. Ask the poller to
    // reseed — otherwise local edits sit unsynced until an unrelated remote
    // change happens to arrive. Reseed is idempotent and stops once seeded.
    None -> {
      state.config.request_seed()
      state
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

fn run_round(state: State) -> State {
  let config = state.config
  // A failed scan skips the round instead of crashing the actor: an
  // unreadable disk would otherwise burn the supervisor's restart budget
  // one round at a time until the whole daemon died.
  case config.scan_local() {
    Error(reason) -> {
      case state.warned_scan {
        True -> Nil
        False ->
          config.report_trouble(
            "local scan failed: " <> reason <> " — skipping this round",
          )
      }
      State(..state, warned_scan: True)
    }
    Ok(locals) -> run_round_with(State(..state, warned_scan: False), locals)
  }
}

fn run_round_with(state: State, locals: List(LocalFile)) -> State {
  let config = state.config
  let assert Some(root_id) = state.root_id
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
  let known_by_id =
    known
    |> list.map(fn(file) { #(file.file_id, file) })
    |> dict.from_list
  let folder_ids_by_path =
    remotes
    |> list.filter(fn(remote) { remote.kind == Folder })
    |> list.map(fn(remote) { #(remote.path, remote.file_id) })
    |> dict.from_list

  let locals = hash_never_synced_twins(config, locals, remotes, known_by_path)
  let locals = hash_rename_candidates(config, locals, remotes, known)
  let locals_by_path =
    locals
    |> list.map(fn(local) { #(local.path, local) })
    |> dict.from_list

  let decisions = reconcile.reconcile_all(locals, remotes, known)
  // The mass-deletion valve: a round that wants to delete most of what was
  // ever synced is an unmounted mirror or an empty/corrupt listing until a
  // human says otherwise. Suppress ONLY the deletions — everything else
  // keeps flowing — and report once per streak.
  let #(decisions, state) = case config.allow_mass_deletion {
    True -> #(decisions, State(..state, warned_mass_deletion: False))
    False ->
      case safety.judge_mass_deletion(decisions, list.length(known)) {
        safety.DeletionsAllowed -> #(
          decisions,
          State(..state, warned_mass_deletion: False),
        )
        safety.DeletionsSuppressed(planned, known_count) -> {
          case state.warned_mass_deletion {
            True -> Nil
            False ->
              config.report_trouble(
                "mass deletion valve: this round would delete "
                <> int.to_string(planned)
                <> " of "
                <> int.to_string(known_count)
                <> " synced files — deletions suppressed (unmounted mirror"
                <> " or empty listing? set IARAGON_ALLOW_MASS_DELETE=1 and"
                <> " restart if this is intended)",
              )
          }
          #(
            safety.drop_deletions(decisions),
            State(..state, warned_mass_deletion: True),
          )
        }
      }
  }
  // The audit line goes out BEFORE dispatching, over the decisions that
  // will actually run (post-valve): bulk forgets and deletions become one
  // explainable journal line instead of a silent state change.
  case decision.describe_workload(decisions) {
    Some(line) -> config.report_activity("round: " <> line)
    None -> Nil
  }
  decisions
  |> list.fold(state, fn(state, decision) {
    case decision {
      decision.DownloadRemote(file_id, _path) -> {
        case dict.get(remote_by_id, file_id) {
          Ok(remote) ->
            config.dispatch_download(
              remote,
              option.from_result(dict.get(known_by_id, file_id)),
            )
          Error(Nil) -> Nil
        }
        state
      }
      decision.DeleteLocal(path) -> {
        case dict.get(known_by_path, path) {
          Ok(file) -> config.dispatch_delete_local(file)
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
        case dict.has_key(state.pending_trashes, file_id) {
          True -> state
          False -> {
            config.dispatch_trash_remote(file_id)
            State(
              ..state,
              pending_trashes: dict.insert(
                state.pending_trashes,
                file_id,
                current_pool_tag(state),
              ),
            )
          }
        }
      decision.Conflict(path, file_id, kind) ->
        resolve_conflict(state, path, file_id, kind, remote_by_id)
      decision.MoveLocal(file_id, from, to) -> {
        case dict.get(known_by_id, file_id), dict.get(remote_by_id, file_id) {
          // A native whose EXTENSION changed did not move — its
          // materialisation changed (NativeDocPolicy switch): renaming
          // would leave stale bytes behind the new extension. Drop the old
          // file and materialise fresh; the download's PutKnown fixes the
          // index.
          Ok(known), Ok(remote) ->
            case remote.kind, changed_extension(from, to) {
              GoogleNative, True -> {
                // The old materialisation is a .desktop link we generated,
                // not user content: the pool force-deletes it (its kind is
                // GoogleNative) and the fresh export lands at the new path.
                config.dispatch_delete_local(known)
                // Fresh export lands at the NEW path, which has no local
                // file yet — nothing to protect.
                config.dispatch_download(remote, None)
              }
              _, _ ->
                dispatch_plain_move(config, known_by_id, file_id, from, to)
            }
          Ok(_known), Error(Nil) ->
            dispatch_plain_move(config, known_by_id, file_id, from, to)
          Error(Nil), _ -> Nil
        }
        state
      }
      decision.MoveRemote(file_id, from, to) ->
        dispatch_move_remote_once(
          state,
          file_id,
          from,
          to,
          locals_by_path,
          folder_ids_by_path,
          root_id,
        )
      decision.AdoptKnown(file_id, path) -> {
        adopt_twin(config, file_id, path, remote_by_id, locals_by_path)
        state
      }
      decision.Noop -> state
    }
  })
}

/// Record a proven-identical twin pair in the sync index without any
/// transfer: the local file's cheap metadata plus the remote identity make
/// the KnownFile snapshot.
fn adopt_twin(
  config: ReconcilerConfig,
  file_id: String,
  path: String,
  remote_by_id: Dict(String, RemoteFile),
  locals_by_path: Dict(String, LocalFile),
) -> Nil {
  case dict.get(remote_by_id, file_id), dict.get(locals_by_path, path) {
    Ok(remote), Ok(local) ->
      process.send(
        config.state_owner,
        state_owner.PutKnown(entry.KnownFile(
          file_id: file_id,
          path: path,
          remote_modified_time: remote.modified_time,
          md5: remote.md5,
          size: local.size,
          local_mtime_seconds: local.mtime_seconds,
          kind: remote.kind,
        )),
      )
    _, _ -> Nil
  }
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
      dispatch_conflict_copy_once(state, path, file_id, remote_by_id)
    // A native's local export was edited and can't be pushed back safely.
    // Under an export policy, preserve the edit exactly like an edit-edit
    // conflict: it moves aside as a new blob and the remote re-exports at the
    // original path. Under LinkFile the local file is a generated .desktop
    // link, not user content — just rewrite it, dropping the edit.
    decision.NativeLocalEdit ->
      case native_edits_become_conflicts(state.config.native_policy) {
        True -> dispatch_conflict_copy_once(state, path, file_id, remote_by_id)
        False -> {
          case dict.get(remote_by_id, file_id) {
            Ok(remote) -> state.config.dispatch_download(remote, None)
            Error(Nil) -> Nil
          }
          state
        }
      }
    decision.LocalEditRemoteDelete | decision.RemoteEditLocalDelete -> {
      process.send(state.config.state_owner, state_owner.ForgetKnown(file_id))
      state
    }
  }
}

fn dispatch_conflict_copy_once(
  state: State,
  path: String,
  file_id: String,
  remote_by_id: Dict(String, RemoteFile),
) -> State {
  case
    dict.has_key(state.pending_conflicts, path),
    dict.get(remote_by_id, file_id)
  {
    False, Ok(remote) -> {
      state.config.dispatch_conflict_copy(
        remote,
        conflicts.build_conflicted_copy_path(path, state.config.today()),
      )
      State(
        ..state,
        pending_conflicts: dict.insert(
          state.pending_conflicts,
          path,
          current_pool_tag(state),
        ),
      )
    }
    _, _ -> state
  }
}

/// A local edit of an exported native becomes a conflicted copy only when the
/// native is materialised as a real editable file — i.e. under an export
/// policy. Under LinkFile it is a generated browser link.
fn native_edits_become_conflicts(policy: NativeDocPolicy) -> Bool {
  case policy {
    entry.LinkFile -> False
    entry.ExportOffice | entry.ExportOdf -> True
  }
}

/// A remote move needs the file's CURRENT remote parent (from the model) and
/// the destination's anchor + missing folder chain (like uploads). It holds
/// both pending keys until settled: its file_id (blocks DeleteRemote) and
/// its destination path (blocks UploadLocal).
fn dispatch_move_remote_once(
  state: State,
  file_id: String,
  from: String,
  to: String,
  locals_by_path: Dict(String, LocalFile),
  folder_ids_by_path: Dict(String, String),
  root_id: String,
) -> State {
  let in_flight = dict.has_key(state.pending_trashes, file_id)
  case in_flight, dict.get(state.model, file_id), dict.get(locals_by_path, to) {
    False, Ok(sighting), Ok(local) -> {
      let #(directory_segments, name) = split_file_name(to)
      let #(anchor_parent_id, missing_folders) =
        resolve_upload_anchor(directory_segments, folder_ids_by_path, root_id)
      state.config.dispatch_move_remote(MoveRemotePlan(
        file_id: file_id,
        from_path: from,
        to_path: to,
        new_name: name,
        old_parent_id: option.unwrap(sighting.parent_id, root_id),
        anchor_parent_id: anchor_parent_id,
        missing_folders: missing_folders,
        local: local,
      ))
      State(
        ..state,
        pending_trashes: dict.insert(
          state.pending_trashes,
          file_id,
          current_pool_tag(state),
        ),
        pending_uploads: dict.insert(
          state.pending_uploads,
          to,
          current_pool_tag(state),
        ),
        pending_move_paths: dict.insert(state.pending_move_paths, file_id, to),
      )
    }
    _, _, _ -> state
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
  let already_in_flight = dict.has_key(state.pending_uploads, path)
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
      State(
        ..state,
        pending_uploads: dict.insert(
          state.pending_uploads,
          path,
          current_pool_tag(state),
        ),
      )
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
/// parent tree and give materialised natives their extension — the export's
/// own (docx/odt/…) under an export policy, `.desktop` for links.
fn plan_remote_files(
  model: Dict(String, RemoteSighting),
  root_id: String,
  policy: NativeDocPolicy,
) -> List(RemoteFile) {
  let sightings = dict.values(model)
  let nodes =
    sightings
    |> list.filter_map(fn(sighting) {
      case classify_sighting(sighting) {
        None -> Error(Nil)
        Some(kind) ->
          // The EFFECTIVE local leaf name — materialisation extension
          // included — goes into path resolution, so disambiguation sees the
          // name that will actually land on disk. Appending the extension
          // after resolution let a Doc `notes` collide with a sibling blob
          // literally named `notes.desktop`: two fileIds on one local path,
          // which overwrite each other locally and then corrupt each other
          // remotely (download-over, upload-back ping-pong).
          Ok(paths.RemoteNode(
            file_id: sighting.file_id,
            name: materialized_name(sighting, kind, policy),
            parent_id: sighting.parent_id,
            is_folder: kind == Folder,
          ))
      }
    })
  let resolved = paths.resolve_paths(nodes, root_id)

  list.filter_map(sightings, fn(sighting) {
    case classify_sighting(sighting), dict.get(resolved, sighting.file_id) {
      Some(kind), Ok(path) ->
        Ok(RemoteFile(
          file_id: sighting.file_id,
          name: sighting.name,
          path: path,
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

fn dispatch_plain_move(
  config: ReconcilerConfig,
  known_by_id: Dict(String, entry.KnownFile),
  file_id: String,
  from: String,
  to: String,
) -> Nil {
  case dict.get(known_by_id, file_id) {
    Ok(known) ->
      config.dispatch_move_local(entry.KnownFile(..known, path: to), from)
    Error(Nil) -> Nil
  }
}

fn changed_extension(from: String, to: String) -> Bool {
  let #(_, from_extension) = paths.split_extension(from)
  let #(_, to_extension) = paths.split_extension(to)
  from_extension != to_extension
}

/// The leaf name a sighting will occupy on disk: the raw remote name for
/// blobs and folders, the name plus the materialisation extension for
/// natives and shortcuts. Computed BEFORE path resolution so disambiguation
/// operates on the name that actually lands in the mirror.
fn materialized_name(
  sighting: RemoteSighting,
  kind: entry.FileKind,
  policy: NativeDocPolicy,
) -> String {
  case kind {
    GoogleNative ->
      case
        native_docs.choose_materialisation(
          sighting.mime_type,
          policy,
          size: sighting.size,
        )
      {
        native_docs.WriteLinkFile -> sighting.name <> ".desktop"
        native_docs.ExportDocument(_export_mime, extension) ->
          sighting.name <> "." <> extension
      }
    entry.Shortcut(_) -> sighting.name <> ".desktop"
    Folder | Blob -> sighting.name
  }
}

fn classify_sighting(sighting: RemoteSighting) -> Option(entry.FileKind) {
  case sighting.mime_type {
    "application/vnd.google-apps.folder" -> Some(Folder)
    "application/vnd.google-apps.shortcut" ->
      // A shortcut without its target (projection gap upstream, or a target
      // the account cannot see) cannot be materialised: keep it out.
      case sighting.shortcut_target_id {
        Some(target_id) -> Some(entry.Shortcut(target_id))
        None -> None
      }
    mime_type ->
      case string.starts_with(mime_type, "application/vnd.google-apps.") {
        True -> Some(GoogleNative)
        False -> Some(Blob)
      }
  }
}

/// A local rename is inferred from size+mtime alone, which two unrelated
/// files can collide on. Hash exactly the candidate destinations so the
/// domain's authoritative md5 check (`content_compatible`) can reject a
/// false pair — renaming the wrong remote onto an unrelated file would
/// silently corrupt the remote. Cheap: only the size+mtime candidates are
/// hashed, and only if not already hashed.
fn hash_rename_candidates(
  config: ReconcilerConfig,
  locals: List(LocalFile),
  remotes: List(RemoteFile),
  known: List(entry.KnownFile),
) -> List(LocalFile) {
  let candidate_paths =
    reconcile.infer_local_renames(locals, remotes, known)
    |> dict.fold(dict.new(), fn(acc, _file_id, to_path) {
      dict.insert(acc, to_path, Nil)
    })

  list.map(locals, fn(local) {
    case dict.has_key(candidate_paths, local.path) && local.md5 == None {
      False -> local
      True ->
        case config.hash_local_file(local.path) {
          Ok(md5) -> LocalFile(..local, md5: Some(md5))
          Error(_) -> local
        }
    }
  })
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
