//// Maps Drive's id-based tree onto POSIX paths for the local mirror. The
//// mapping is lossy by nature — names are not unique within a folder and may
//// contain "/" — so the rules here are what keep it deterministic:
////
//// - names are sanitized ("/" becomes "_");
//// - among same-named siblings the lowest file_id keeps the natural name and
////   every other twin gets its id woven in before the extension;
//// - only nodes reachable from the mirror root are mapped (restrictToMyDrive
////   already narrows the change feed; shared/orphaned items are excluded).
////
//// Pure: stdlib only, like everything under domain/.

import gleam/dict.{type Dict}
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
    let sanitized = string.replace(node.name, "/", "_")
    let final_name = case set.contains(taken, sanitized) {
      False -> sanitized
      True -> weave_id(sanitized, node.file_id)
    }
    #(set.insert(taken, final_name), #(node, final_name))
  })
  |> fn(result) { result.1 }
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
