import iaragon/infrastructure/auth/token_store.{StoredTokens}
import simplifile

// The store path is injected, so tests write under the build directory
// instead of the user's real ~/.config.

const scratch_dir = "build/test-scratch/token_store"

fn a_store_path(name: String) -> String {
  scratch_dir <> "/" <> name <> "/tokens.json"
}

pub fn tokens_survive_a_save_load_round_trip_test() {
  let path = a_store_path("round_trip")
  let tokens =
    StoredTokens(
      access_token: "at-1",
      refresh_token: "rt-1",
      expires_at_unix: 1_800_000_000,
    )
  let assert Ok(Nil) = token_store.save_tokens(path, tokens)
  assert token_store.load_tokens(path) == Ok(tokens)
}

pub fn saving_creates_missing_parent_directories_test() {
  let path = a_store_path("deep/nested/dirs")
  let tokens =
    StoredTokens(access_token: "a", refresh_token: "r", expires_at_unix: 1)
  let assert Ok(Nil) = token_store.save_tokens(path, tokens)
  assert simplifile.is_file(path) == Ok(True)
}

pub fn the_saved_token_file_is_owner_only_test() {
  let path = a_store_path("perms")
  let tokens =
    StoredTokens(access_token: "a", refresh_token: "r", expires_at_unix: 1)
  let assert Ok(Nil) = token_store.save_tokens(path, tokens)
  let assert Ok(info) = simplifile.file_info(path)
  // Tokens are secrets: 0600, never group/other readable.
  assert simplifile.file_info_permissions_octal(info) == 0o600
}

pub fn loading_a_missing_file_reports_unreadable_test() {
  let assert Error(token_store.Unreadable(_)) =
    token_store.load_tokens(a_store_path("missing"))
}

pub fn loading_a_corrupted_file_reports_corrupted_test() {
  let path = a_store_path("corrupted")
  let assert Ok(Nil) =
    simplifile.create_directory_all(scratch_dir <> "/corrupted")
  let assert Ok(Nil) = simplifile.write(to: path, contents: "not json at all")
  assert token_store.load_tokens(path) == Error(token_store.Corrupted)
}
