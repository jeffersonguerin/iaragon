import gleam/dict
import gleam/option.{None, Some}
import iaragon/domain/paths.{RemoteNode}

// Mapping Drive's id-based tree onto POSIX paths is lossy: names are not
// unique within a folder and may contain "/". These tests pin the rules:
// deterministic disambiguation, sanitization, and exclusion of anything not
// reachable from the mirror root.

fn a_folder(id: String, name: String, parent: String) -> paths.RemoteNode {
  RemoteNode(file_id: id, name: name, parent_id: Some(parent), is_folder: True)
}

fn a_file(id: String, name: String, parent: String) -> paths.RemoteNode {
  RemoteNode(file_id: id, name: name, parent_id: Some(parent), is_folder: False)
}

pub fn nested_files_get_slash_joined_paths_test() {
  let resolved =
    paths.resolve_paths(
      [
        a_folder("id-docs", "docs", "root"),
        a_file("id-1", "report.txt", "id-docs"),
      ],
      root_id: "root",
    )
  assert dict.get(resolved, "id-docs") == Ok("docs")
  assert dict.get(resolved, "id-1") == Ok("docs/report.txt")
}

// Names come from the Drive API and are untrusted: "..", ".", empty, and
// names carrying "/" must never resolve to a path segment that escapes the
// mirror root when the pool joins root_dir <> "/" <> path.
pub fn dot_dot_names_cannot_escape_the_mirror_test() {
  let resolved =
    paths.resolve_paths(
      [
        a_folder("id-esc", "..", "root"),
        a_file("id-1", "payload", "id-esc"),
      ],
      root_id: "root",
    )
  let assert Ok(folder_path) = dict.get(resolved, "id-esc")
  assert folder_path == "_.."
  assert dict.get(resolved, "id-1") == Ok("_../payload")
}

pub fn single_dot_and_empty_names_are_neutralised_test() {
  let resolved =
    paths.resolve_paths(
      [a_file("id-dot", ".", "root"), a_file("id-empty", "", "root")],
      root_id: "root",
    )
  assert dict.get(resolved, "id-dot") == Ok("_.")
  assert dict.get(resolved, "id-empty") == Ok("_")
}

pub fn slash_in_name_cannot_introduce_a_path_segment_test() {
  let resolved =
    paths.resolve_paths(
      [a_file("id-1", "../etc/passwd", "root")],
      root_id: "root",
    )
  // "/" becomes "_", so no new segment and no traversal.
  assert dict.get(resolved, "id-1") == Ok(".._etc_passwd")
}

pub fn files_in_the_root_keep_bare_names_test() {
  let resolved =
    paths.resolve_paths([a_file("id-1", "a.txt", "root")], root_id: "root")
  assert dict.get(resolved, "id-1") == Ok("a.txt")
}

pub fn duplicate_names_are_disambiguated_deterministically_test() {
  // Order in the input list must not matter: the lowest file_id keeps the
  // natural name, every other twin gets its id woven in before the extension.
  let resolved =
    paths.resolve_paths(
      [
        a_file("id-b", "report.txt", "root"),
        a_file("id-a", "report.txt", "root"),
      ],
      root_id: "root",
    )
  assert dict.get(resolved, "id-a") == Ok("report.txt")
  assert dict.get(resolved, "id-b") == Ok("report (id-b).txt")
}

// PENTEST — on a shared Drive a collaborator can read the fileIds the API
// assigns, then craft a sibling whose NATURAL name equals the woven name
// another twin will receive. If the woven fallback is not itself checked for
// freedom, two distinct fileIds collapse onto one local path — a silent
// overwrite / dropped file. Every fileId must map to a DISTINCT path.
pub fn a_crafted_name_cannot_force_a_path_collision_test() {
  // Sorted by file_id: id-a, id-b, id-c.
  //  id-a "doc.txt"        -> "doc.txt"
  //  id-b "doc (id-c).txt" -> free, taken
  //  id-c "doc.txt"        -> taken -> weave -> "doc (id-c).txt" -> ALSO taken
  let resolved =
    paths.resolve_paths(
      [
        a_file("id-a", "doc.txt", "root"),
        a_file("id-b", "doc (id-c).txt", "root"),
        a_file("id-c", "doc.txt", "root"),
      ],
      root_id: "root",
    )
  let assert Ok(path_a) = dict.get(resolved, "id-a")
  let assert Ok(path_b) = dict.get(resolved, "id-b")
  let assert Ok(path_c) = dict.get(resolved, "id-c")
  assert path_a != path_b
  assert path_a != path_c
  assert path_b != path_c
}

// PENTEST — a Drive name carrying a NUL or other control character would,
// unsanitized, reach the filesystem op and error/truncate at the NUL. Every
// control character must be neutralised into an inert segment.
pub fn control_characters_in_a_name_are_neutralised_test() {
  let resolved =
    paths.resolve_paths(
      [a_file("id-1", "a\u{0}b\u{1f}c\td.txt", "root")],
      root_id: "root",
    )
  assert dict.get(resolved, "id-1") == Ok("a_b_c_d.txt")
}

pub fn duplicate_folder_names_are_disambiguated_too_test() {
  let resolved =
    paths.resolve_paths(
      [
        a_folder("id-2", "photos", "root"),
        a_folder("id-1", "photos", "root"),
        a_file("id-3", "cat.jpg", "id-2"),
      ],
      root_id: "root",
    )
  assert dict.get(resolved, "id-1") == Ok("photos")
  assert dict.get(resolved, "id-2") == Ok("photos (id-2)")
  assert dict.get(resolved, "id-3") == Ok("photos (id-2)/cat.jpg")
}

pub fn slashes_in_names_are_sanitized_test() {
  let resolved =
    paths.resolve_paths([a_file("id-1", "a/b.txt", "root")], root_id: "root")
  assert dict.get(resolved, "id-1") == Ok("a_b.txt")
}

pub fn names_colliding_after_sanitization_are_disambiguated_test() {
  let resolved =
    paths.resolve_paths(
      [a_file("id-a", "a/b.txt", "root"), a_file("id-b", "a_b.txt", "root")],
      root_id: "root",
    )
  assert dict.get(resolved, "id-a") == Ok("a_b.txt")
  assert dict.get(resolved, "id-b") == Ok("a_b (id-b).txt")
}

pub fn nodes_not_reachable_from_the_root_are_excluded_test() {
  let resolved =
    paths.resolve_paths(
      [
        a_file("id-1", "mine.txt", "root"),
        a_file("id-2", "shared.txt", "someone-elses-folder"),
        RemoteNode(
          file_id: "id-3",
          name: "parentless",
          parent_id: None,
          is_folder: False,
        ),
      ],
      root_id: "root",
    )
  assert dict.get(resolved, "id-1") == Ok("mine.txt")
  assert dict.get(resolved, "id-2") == Error(Nil)
  assert dict.get(resolved, "id-3") == Error(Nil)
}

pub fn a_self_referencing_folder_cannot_loop_the_resolver_test() {
  let resolved =
    paths.resolve_paths(
      [a_folder("id-evil", "evil", "id-evil"), a_file("id-1", "ok.txt", "root")],
      root_id: "root",
    )
  assert dict.get(resolved, "id-1") == Ok("ok.txt")
  assert dict.get(resolved, "id-evil") == Error(Nil)
}
