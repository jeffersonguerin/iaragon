import iaragon/infrastructure/fs/hashing
import simplifile

const scratch_dir = "build/test-scratch/hashing"

pub fn hashes_match_drive_style_lowercase_hex_md5_test() {
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir)
  let assert Ok(Nil) =
    simplifile.write(to: scratch_dir <> "/hello.txt", contents: "hello\n")
  // md5("hello\n") — verified locally with `md5sum`.
  assert hashing.hash_mirror_file(scratch_dir, "hello.txt")
    == Ok("b1946ac92492d2347c6235b4d2611184")
}

pub fn a_missing_file_reports_an_error_test() {
  let assert Error(_) = hashing.hash_mirror_file(scratch_dir, "ghost.txt")
}
