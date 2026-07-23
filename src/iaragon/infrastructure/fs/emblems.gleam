//// Paints sync-status emblems on mirrored files as GVfs metadata
//// (`metadata::emblems`), which GTK file managers (Nautilus, Nemo, Caja)
//// render on the icon — no file-manager extension needed. KDE's Dolphin
//// does not read gvfs metadata; it would need its own adapter.
////
//// Everything goes through `gio set` run WITHOUT a shell (argument vector
//// straight to the executable), and the composition probes real support
//// once at boot: headless machines (no gvfsd-metadata) get a no-op painter
//// instead of one doomed gio call per transfer.

import gleam/result
import iaragon/domain/entry.{type SyncStatus, Synced, Syncing}
import simplifile

/// Run an executable to completion: Ok(stdout) on exit 0, Error(output)
/// otherwise. No shell is involved.
@external(erlang, "iaragon_exec_ffi", "run_command")
pub fn run_executable(
  executable: String,
  arguments: List(String),
) -> Result(String, String)

/// Emblem names follow the freedesktop icon naming conventions; how they
/// look (or whether a theme ships them) varies per theme.
fn choose_emblem(status: SyncStatus) -> String {
  case status {
    Syncing -> "emblem-synchronizing"
    Synced -> "emblem-default"
  }
}

pub fn paint_status(
  run: fn(String, List(String)) -> Result(String, String),
  mirror_root: String,
  path: String,
  status: SyncStatus,
) -> Result(Nil, String) {
  run("gio", [
    "set",
    "-t",
    "stringv",
    mirror_root <> "/" <> path,
    "metadata::emblems",
    choose_emblem(status),
  ])
  |> result.replace(Nil)
}

/// Prove emblem support by actually setting metadata on a probe file: the
/// gio CLI may exist on machines whose gvfs cannot store metadata at all
/// (headless boxes), and only a real write tells the difference.
pub fn detect_emblem_support(
  run: fn(String, List(String)) -> Result(String, String),
  probe_dir: String,
) -> Bool {
  let probe = ".iaragon-emblem-probe"
  let supported = {
    use Nil <- result.try(
      simplifile.create_directory_all(probe_dir)
      |> result.replace_error("cannot create probe dir"),
    )
    use Nil <- result.try(
      simplifile.write(to: probe_dir <> "/" <> probe, contents: "")
      |> result.replace_error("cannot write probe file"),
    )
    paint_status(run, probe_dir, probe, Synced)
  }
  let _ = simplifile.delete(probe_dir <> "/" <> probe)
  supported == Ok(Nil)
}

/// The composition-facing constructor: a painter wired to the real gio when
/// the machine supports it, a silent no-op otherwise. Painting failures are
/// swallowed — an emblem is decoration, never worth failing a transfer for.
pub fn build_status_painter(
  mirror_root: String,
) -> fn(String, SyncStatus) -> Nil {
  case detect_emblem_support(run_executable, mirror_root) {
    True -> fn(path, status) {
      let _ = paint_status(run_executable, mirror_root, path, status)
      Nil
    }
    False -> fn(_path, _status) { Nil }
  }
}
