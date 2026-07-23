//// Maps Drive's id-based tree onto POSIX paths for the local mirror. The
//// mapping is lossy by nature — names are not unique within a folder and may
//// contain "/" — so the rules here are what keep it deterministic:
////
//// - names are sanitized: "/" becomes "_", and the traversal payloads "",
////   ".", ".." are neutralised (they come from the API and are untrusted);
//// - among same-named siblings the lowest file_id keeps the natural name and
////   every other twin gets its id woven in before the extension;
//// - only nodes reachable from the mirror root are mapped (restrictToMyDrive
////   already narrows the change feed; shared/orphaned items are excluded).
////
//// Pure: stdlib only, like everything under domain/.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string

/// The minimum a node must reveal to be placed: identity, label, and where
/// it hangs. (This is not `entry.RemoteFile` because that type already
/// carries a resolved path — the very thing this module produces.)
pub type RemoteNode {
  RemoteNode(
    file_id: String,
    name: String,
    parent_id: Option(String),
    is_folder: Bool,
  )
}

/// Resolve every reachable node to a path relative to the mirror root.
pub fn resolve_paths(
  nodes: List(RemoteNode),
  root_id root_id: String,
) -> Dict(String, String) {
  let children_by_parent =
    list.fold(nodes, dict.new(), fn(acc, node) {
      case node.parent_id {
        None -> acc
        Some(parent_id) ->
          dict.upsert(acc, parent_id, fn(siblings) {
            case siblings {
              Some(siblings) -> [node, ..siblings]
              None -> [node]
            }
          })
      }
    })
  descend(root_id, "", children_by_parent, dict.new())
}

fn descend(
  folder_id: String,
  prefix: String,
  children_by_parent: Dict(String, List(RemoteNode)),
  resolved: Dict(String, String),
) -> Dict(String, String) {
  case dict.get(children_by_parent, folder_id) {
    Error(Nil) -> resolved
    Ok(children) ->
      list.fold(assign_final_names(children), resolved, fn(resolved, child) {
        let #(node, name) = child
        // A node already placed (duplicate id in a malformed feed) must not
        // be walked again — this is what makes loops impossible.
        case dict.has_key(resolved, node.file_id) {
          True -> resolved
          False -> {
            let path = prefix <> name
            let resolved = dict.insert(resolved, node.file_id, path)
            case node.is_folder {
              True ->
                descend(node.file_id, path <> "/", children_by_parent, resolved)
              False -> resolved
            }
          }
        }
      })
  }
}

/// Decide each sibling's final file name: sanitize, then disambiguate
/// deterministically by file_id order.
fn assign_final_names(
  siblings: List(RemoteNode),
) -> List(#(RemoteNode, String)) {
  siblings
  |> list.sort(fn(a, b) { string.compare(a.file_id, b.file_id) })
  |> list.map_fold(set.new(), fn(taken: Set(String), node) {
    let final_name = pick_free_name(node.name, node.file_id, taken)
    #(set.insert(taken, final_name), #(node, final_name))
  })
  |> fn(result) { result.1 }
}

/// Choose a name no earlier sibling has claimed. The sanitized name wins if
/// free; otherwise the file_id is woven in; and if even THAT collides (a
/// sibling can be crafted so its natural name equals another's woven form),
/// numeric variants are appended until one is free — the same discipline as
/// conflicted-copy naming. Without the final check two distinct fileIds could
/// map to one path, silently dropping a file.
fn pick_free_name(name: String, file_id: String, taken: Set(String)) -> String {
  let sanitized = sanitize_segment(name)
  case set.contains(taken, sanitized) {
    False -> sanitized
    True -> {
      let woven = weave_id(sanitized, file_id)
      case set.contains(taken, woven) {
        False -> woven
        True -> next_free_variant(woven, 2, taken)
      }
    }
  }
}

fn next_free_variant(base: String, n: Int, taken: Set(String)) -> String {
  let #(stem, extension) = split_extension(base)
  let candidate = case extension {
    "" -> stem <> " (" <> int.to_string(n) <> ")"
    extension -> stem <> " (" <> int.to_string(n) <> ")." <> extension
  }
  case set.contains(taken, candidate) {
    False -> candidate
    True -> next_free_variant(base, n + 1, taken)
  }
}

/// Turn one untrusted Drive name into one safe POSIX path segment. Names
/// come from the API and are attacker-influenceable: "/" would introduce a
/// new segment, and "", ".", ".." are the classic traversal payloads (a
/// folder literally named ".." would make the mirror climb out of its root
/// when joined as root_dir <> "/" <> path). "/" becomes "_"; the three
/// dangerous segments are neutralised with a leading "_" so they stay
/// single, inert names.
fn sanitize_segment(name: String) -> String {
  let replaced = name |> string.replace("/", "_") |> strip_control_characters
  case replaced {
    "" | "." | ".." -> "_" <> replaced
    other -> other
  }
}

/// Replace ASCII control characters (including NUL and tab/newline) with "_".
/// A NUL would truncate the name at the filesystem boundary; the others make
/// unusable segments. Printable characters (including all of Unicode ≥ 0x20,
/// bar 0x7f DEL) pass through unchanged.
fn strip_control_characters(name: String) -> String {
  name
  |> string.to_utf_codepoints
  |> list.map(fn(codepoint) {
    case string.utf_codepoint_to_int(codepoint) {
      value if value < 0x20 || value == 0x7f -> "_"
      _ -> string.from_utf_codepoints([codepoint])
    }
  })
  |> string.concat
}

fn weave_id(name: String, file_id: String) -> String {
  let #(stem, extension) = split_extension(name)
  case extension {
    "" -> stem <> " (" <> file_id <> ")"
    extension -> stem <> " (" <> file_id <> ")." <> extension
  }
}

/// Split a file name at the last dot: #(stem, extension). Dotfiles and
/// extensionless names come back whole with an empty extension. Public
/// because conflicted-copy naming reuses the same rule.
pub fn split_extension(name: String) -> #(String, String) {
  case string.split_once(string.reverse(name), ".") {
    Ok(#(reversed_extension, reversed_stem)) ->
      case reversed_stem {
        // A leading dot ("gitignore." reversed) is a dotfile, not an extension.
        "" -> #(name, "")
        _ -> #(
          string.reverse(reversed_stem),
          string.reverse(reversed_extension),
        )
      }
    Error(Nil) -> #(name, "")
  }
}
