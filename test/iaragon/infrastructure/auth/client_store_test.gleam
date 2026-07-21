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

pub fn a_missing_client_file_reports_unreadable_test() {
  let assert Error(client_store.Unreadable(_)) =
    client_store.load_client(scratch_dir <> "/missing/oauth_client.json")
}

pub fn a_corrupted_client_file_reports_corrupted_test() {
  let path = scratch_dir <> "/bad/oauth_client.json"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir <> "/bad")
  let assert Ok(Nil) = simplifile.write(to: path, contents: "{}")
  assert client_store.load_client(path) == Error(client_store.Corrupted("{}"))
}
