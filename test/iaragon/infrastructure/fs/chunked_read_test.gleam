import iaragon/infrastructure/fs/chunked_read.{EndOfFile, NextChunk}
import simplifile

// Resumable uploads send 256 KB-multiple chunks; the reader must hand back a
// file piece by piece without ever loading it whole.

const scratch_dir = "build/test-scratch/chunked_read"

pub fn a_file_is_read_in_chunks_until_eof_test() {
  let path = scratch_dir <> "/five.bin"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir)
  let assert Ok(Nil) = simplifile.write(to: path, contents: "abcde")

  let assert Ok(handle) = chunked_read.open_read(path)
  assert chunked_read.read_chunk(handle, 2) == Ok(NextChunk(<<"ab":utf8>>))
  assert chunked_read.read_chunk(handle, 2) == Ok(NextChunk(<<"cd":utf8>>))
  // The final piece may be shorter than the chunk size.
  assert chunked_read.read_chunk(handle, 2) == Ok(NextChunk(<<"e":utf8>>))
  assert chunked_read.read_chunk(handle, 2) == Ok(EndOfFile)
  assert chunked_read.close(handle) == Ok(Nil)
}

pub fn a_missing_file_cannot_be_opened_test() {
  let assert Error(_) = chunked_read.open_read(scratch_dir <> "/ghost.bin")
}

// The upload side of the same UTF-8 trap as the download FFI: a path arrives
// as a UTF-8 binary, and binary_to_list/1 turns it into raw bytes that Erlang
// then reads back as codepoints. An accented file would look missing and never
// upload, even though it sits right there.
pub fn an_accented_file_can_be_opened_test() {
  let path = scratch_dir <> "/Relatório de Condições.csv"
  let assert Ok(Nil) = simplifile.create_directory_all(scratch_dir)
  let assert Ok(Nil) = simplifile.write(to: path, contents: "ok")

  let assert Ok(handle) = chunked_read.open_read(path)
  assert chunked_read.read_chunk(handle, 8) == Ok(NextChunk(<<"ok":utf8>>))
  assert chunked_read.close(handle) == Ok(Nil)
}
