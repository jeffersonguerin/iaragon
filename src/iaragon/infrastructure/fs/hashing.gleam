//// On-demand md5 of a mirror file, in the lowercase-hex form Drive reports
//// for blobs. Reads the whole file into memory — acceptable because the
//// reconciler only hashes never-synced twins, not the whole mirror.

import gleam/bit_array
import gleam/crypto
import gleam/result
import gleam/string
import simplifile

pub fn hash_mirror_file(
  root_dir: String,
  relative_path: String,
) -> Result(String, String) {
  use bytes <- result.try(
    simplifile.read_bits(from: root_dir <> "/" <> relative_path)
    |> result.map_error(simplifile.describe_error),
  )
  crypto.hash(crypto.Md5, bytes)
  |> bit_array.base16_encode
  |> string.lowercase
  |> Ok
}
