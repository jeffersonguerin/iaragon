import iaragon/domain/conflicts

// Edit-edit conflicts resolve Dropbox-style: the local version moves aside
// under a dated "conflicted copy" name (visible on both sides once synced)
// and the remote version takes the original path.

pub fn the_marker_goes_before_the_extension_test() {
  assert conflicts.build_conflicted_copy_path("docs/report.txt", "2026-07-22")
    == "docs/report (conflicted copy 2026-07-22).txt"
}

pub fn extensionless_names_get_the_marker_appended_test() {
  assert conflicts.build_conflicted_copy_path("notes", "2026-07-22")
    == "notes (conflicted copy 2026-07-22)"
}

pub fn dotfiles_are_not_split_test() {
  assert conflicts.build_conflicted_copy_path(".env", "2026-07-22")
    == ".env (conflicted copy 2026-07-22)"
}

pub fn the_directory_is_preserved_test() {
  assert conflicts.build_conflicted_copy_path("a/b/c.tar.gz", "2026-07-22")
    == "a/b/c.tar (conflicted copy 2026-07-22).gz"
}
