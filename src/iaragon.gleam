import envoy
import gleam/erlang/process
import iaragon/infrastructure/persistence/state_db
import iaragon/infrastructure/supervision
import simplifile

pub fn main() -> Nil {
  let assert Ok(home) = envoy.get("HOME")
  let data_dir = home <> "/.local/share/iaragon"
  let assert Ok(Nil) = simplifile.create_directory_all(data_dir)
  let assert Ok(db) = state_db.open(data_dir <> "/state.db")
  let assert Ok(_daemon) =
    supervision.start_daemon(store: state_db.build_state_store(db))
  process.sleep_forever()
}
