import gleam/erlang/process
import gleam/string
import iaragon/domain/entry.{Synced, Syncing}
import iaragon/infrastructure/fs/emblems

// Sync-status emblems are written as GVfs metadata (`metadata::emblems`),
// which GTK file managers (Nautilus/Nemo/Caja) render on the file icon. The
// gio invocation goes through an injected runner, so tests never depend on a
// desktop session — and the composition probes real support once, falling
// back to a no-op painter on machines without gvfs metadata (headless boxes,
// this container).

// --- The executable runner (FFI) ------------------------------------------------

pub fn running_an_executable_captures_its_output_test() {
  assert emblems.run_executable("echo", ["hello", "emblems"])
    == Ok("hello emblems\n")
}

pub fn a_failing_executable_reports_an_error_test() {
  let assert Error(_) = emblems.run_executable("false", [])
}

pub fn a_missing_executable_reports_an_error_test() {
  let assert Error(reason) = emblems.run_executable("no-such-tool-iaragon", [])
  assert string.contains(reason, "not found")
}

// --- Painting emblems -----------------------------------------------------------

pub fn painting_synced_sets_the_default_emblem_test() {
  let calls = process.new_subject()
  let run = fn(exe, args) {
    process.send(calls, #(exe, args))
    Ok("")
  }

  assert emblems.paint_status(run, "/mirror", "docs/report.txt", Synced)
    == Ok(Nil)

  assert process.receive(calls, 100)
    == Ok(
      #("gio", [
        "set",
        "-t",
        "stringv",
        "/mirror/docs/report.txt",
        "metadata::emblems",
        "emblem-default",
      ]),
    )
}

pub fn painting_syncing_sets_the_synchronizing_emblem_test() {
  let calls = process.new_subject()
  let run = fn(exe, args) {
    process.send(calls, #(exe, args))
    Ok("")
  }

  assert emblems.paint_status(run, "/mirror", "big.bin", Syncing) == Ok(Nil)

  let assert Ok(#("gio", args)) = process.receive(calls, 100)
  assert args
    == [
      "set",
      "-t",
      "stringv",
      "/mirror/big.bin",
      "metadata::emblems",
      "emblem-synchronizing",
    ]
}

pub fn painting_failure_sets_the_important_emblem_test() {
  let calls = process.new_subject()
  let run = fn(exe, args) {
    process.send(calls, #(exe, args))
    Ok("")
  }

  assert emblems.paint_status(run, "/mirror", "doomed.txt", entry.SyncFailed)
    == Ok(Nil)

  let assert Ok(#("gio", args)) = process.receive(calls, 100)
  assert args
    == [
      "set",
      "-t",
      "stringv",
      "/mirror/doomed.txt",
      "metadata::emblems",
      "emblem-important",
    ]
}

pub fn a_refused_gio_call_propagates_the_error_test() {
  let run = fn(_exe, _args) { Error("Setting attribute not supported") }
  let assert Error(_) =
    emblems.paint_status(run, "/mirror", "docs/report.txt", Synced)
}

// --- Support detection ----------------------------------------------------------

pub fn support_follows_what_a_real_probe_write_says_test() {
  assert emblems.detect_emblem_support(
      fn(_exe, _args) { Ok("") },
      "build/test-scratch/emblems/supported",
    )
    == True
  assert emblems.detect_emblem_support(
      fn(_exe, _args) { Error("not supported") },
      "build/test-scratch/emblems/unsupported",
    )
    == False
}

pub fn this_headless_container_has_no_emblem_support_test() {
  // Honest environment check: gio exists here but gvfs metadata does not,
  // so the composition must wire the no-op painter. On a real desktop this
  // very probe is what turns the painter on.
  assert emblems.detect_emblem_support(
      emblems.run_executable,
      "build/test-scratch/emblems/real",
    )
    == False
}
