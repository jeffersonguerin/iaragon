//// Chunked file reading over a thin `file` FFI, for resumable uploads:
//// pieces of a configurable size, never the whole file in memory. The last
//// piece may be shorter; after it comes `EndOfFile`.

pub type FileHandle

pub type Chunk {
  NextChunk(bytes: BitArray)
  EndOfFile
}

@external(erlang, "iaragon_file_ffi", "open_read")
pub fn open_read(path: String) -> Result(FileHandle, String)

@external(erlang, "iaragon_file_ffi", "read_chunk")
pub fn read_chunk(handle: FileHandle, size: Int) -> Result(Chunk, String)

@external(erlang, "iaragon_file_ffi", "close")
pub fn close(handle: FileHandle) -> Result(Nil, String)
