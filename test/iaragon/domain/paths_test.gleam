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
