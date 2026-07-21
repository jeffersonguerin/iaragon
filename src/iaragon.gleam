import gleam/erlang/process
import iaragon/infrastructure/supervision

pub fn main() -> Nil {
  let assert Ok(_daemon) = supervision.start_daemon()
  process.sleep_forever()
}
