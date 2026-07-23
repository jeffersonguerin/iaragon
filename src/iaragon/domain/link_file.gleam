//// Builds the `.desktop` link file the mirror writes for a Google-native doc
//// (under the LinkFile policy) or a shortcut. Pure: the caller only writes
//// the bytes.
////
//// The display name and target id come straight from the Drive API and are
//// ATTACKER-INFLUENCEABLE (a file shared into the user's Drive controls its
//// name). Every value is therefore escaped per the Desktop Entry spec before
//// interpolation: a name carrying a newline must not be able to start a new
//// line and inject a second `Type=`/`Exec=` key. GKeyFile (used by GTK file
//// managers) honours the LAST value of a duplicated key, so an unescaped
//// newline would turn a click on the link into arbitrary code execution.

import gleam/string

/// Assemble the Desktop Entry contents for a link pointing at `target_id`.
pub fn build(name name: String, target_id target_id: String) -> String {
  "[Desktop Entry]\n"
  <> "Type=Link\n"
  <> "Name="
  <> escape_value(name)
  <> "\n"
  <> "URL=https://drive.google.com/open?id="
  <> escape_value(target_id)
  <> "\n"
}

/// Escape a Desktop Entry string value. Backslash MUST be escaped first, so
/// the backslashes introduced by the control-character replacements are not
/// doubled; the newline/carriage-return escapes are the ones that actually
/// close the injection (they keep the value on a single physical line).
fn escape_value(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}
