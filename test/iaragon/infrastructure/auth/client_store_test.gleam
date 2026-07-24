import iaragon/infrastructure/auth/client_store
import iaragon/infrastructure/auth/oauth.{OauthClient}
import simplifile

const scratch_dir = "build/test-scratch/client_store"

pub fn loads_the_oauth_client_from_json_test() {
  let path = scratch_dir <> "/ok/oauth_client.json"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir <> "/ok")
  let assert Ok(Nil) =
    simplifile.write(
      to: path,
      contents: "{\"client_id\":\"abc.apps.googleusercontent.com\","
        <> "\"client_secret\":\"s3cr3t\"}",
    )
  assert client_store.load_client(path)
    == Ok(OauthClient(
      client_id: "abc.apps.googleusercontent.com",
      client_secret: "s3cr3t",
    ))
}

// The config dir holds the client secret and, after login, the tokens.
// save_tokens already tightens the dir when it writes — but before the first
// successful login (or on a daemon that runs without ever logging in) the
// user-created dir sits at the umask default, world-readable. protect must
// close that window from BOTH entry points (login and daemon boot).

pub fn protecting_tightens_a_lax_dir_and_client_file_test() {
  let dir = scratch_dir <> "/protect_lax"
  let path = dir <> "/oauth_client.json"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.set_permissions_octal(dir, 0o755)
  let assert Ok(Nil) = simplifile.write(to: path, contents: "{}")
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, 0o644)

  let assert Ok(Nil) = client_store.protect_config_dir(dir)

  let assert Ok(dir_info) = simplifile.file_info(dir)
  assert simplifile.file_info_permissions_octal(dir_info) == 0o700
  let assert Ok(file_info) = simplifile.file_info(path)
  assert simplifile.file_info_permissions_octal(file_info) == 0o600
}

pub fn protecting_creates_a_missing_dir_owner_only_test() {
  let dir = scratch_dir <> "/protect_fresh/nested"
  let assert Ok(Nil) = client_store.protect_config_dir(dir)
  let assert Ok(dir_info) = simplifile.file_info(dir)
  assert simplifile.file_info_permissions_octal(dir_info) == 0o700
}

pub fn protecting_succeeds_when_the_client_file_is_absent_test() {
  let dir = scratch_dir <> "/protect_no_client"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = client_store.protect_config_dir(dir)
  let assert Ok(dir_info) = simplifile.file_info(dir)
  assert simplifile.file_info_permissions_octal(dir_info) == 0o700
}

pub fn a_missing_client_file_reports_unreadable_test() {
  let assert Error(client_store.Unreadable(_)) =
    client_store.load_client(scratch_dir <> "/missing/oauth_client.json")
}

pub fn a_corrupted_client_file_reports_corrupted_test() {
  let path = scratch_dir <> "/bad/oauth_client.json"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir <> "/bad")
  let assert Ok(Nil) = simplifile.write(to: path, contents: "{}")
  assert client_store.load_client(path) == Error(client_store.Corrupted)
}

// Google's console hands you a client_secret_*.json to DOWNLOAD, shaped
// {"installed": {"client_id": ..., "client_secret": ..., ...}} (or "web").
// Accepting it verbatim spares the user hand-crafting oauth_client.json —
// the single biggest paper cut in first-run setup.

pub fn loads_the_google_downloaded_installed_json_test() {
  let path = scratch_dir <> "/installed/oauth_client.json"
  let assert Ok(Nil) =
    simplifile.create_directory_all(scratch_dir <> "/installed")
  let assert Ok(Nil) =
    simplifile.write(
      to: path,
      contents: "{\"installed\":{\"client_id\":\"abc.apps.googleusercontent.com\","
        <> "\"project_id\":\"my-proj\",\"client_secret\":\"s3cr3t\","
        <> "\"redirect_uris\":[\"http://localhost\"]}}",
    )
  assert client_store.load_client(path)
    == Ok(OauthClient(
      client_id: "abc.apps.googleusercontent.com",
      client_secret: "s3cr3t",
    ))
}

pub fn loads_the_google_downloaded_web_json_test() {
  let path = scratch_dir <> "/web/oauth_client.json"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir <> "/web")
  let assert Ok(Nil) =
    simplifile.write(
      to: path,
      contents: "{\"web\":{\"client_id\":\"w.apps.googleusercontent.com\","
        <> "\"client_secret\":\"web-secret\"}}",
    )
  assert client_store.load_client(path)
    == Ok(OauthClient(
      client_id: "w.apps.googleusercontent.com",
      client_secret: "web-secret",
    ))
}
