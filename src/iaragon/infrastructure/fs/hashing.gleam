//// On-demand md5 of a mirror file, in the lowercase-hex form Drive reports
//// for blobs. Hashed in 1 MiB windows through the same chunked-read FFI the
//// upload path uses: peak memory stays one window regardless of file size —
//// a whole-file read would spike the heap by the file's full size (measured:
//// 32 MiB file → +32 MiB peak) exactly when the reconciler hashes a big
//// never-synced twin.

import gleam/bit_array
import gleam/crypto.{type Hasher}
import gleam/result
import gleam/string
import iaragon/infrastructure/fs/chunked_read.{
  type FileHandle, EndOfFile, NextChunk,
}

const window_bytes = 1_048_576

pub fn hash_mirror_file(
  root_dir: String,
  relative_path: String,
) -> Result(String, String) {
  use handle <- result.try(chunked_read.open_read(
    root_dir <> "/" <> relative_path,
  ))
  let outcome = hash_windows(handle, crypto.new_hasher(crypto.Md5))
  let _ = chunked_read.close(handle)
  outcome
}

fn hash_windows(handle: FileHandle, hasher: Hasher) -> Result(String, String) {
  use chunk <- result.try(chunked_read.read_chunk(handle, window_bytes))
  case chunk {
    EndOfFile ->
      crypto.digest(hasher)
      |> bit_array.base16_encode
      |> string.lowercase
      |> Ok
    NextChunk(bytes) -> hash_windows(handle, crypto.hash_chunk(hasher, bytes))
  }
}
