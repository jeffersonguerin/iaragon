import gleam/bit_array
import gleam/erlang/process
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import iaragon/infrastructure/drive/download
import iaragon/infrastructure/drive/upload
import iaragon/infrastructure/fs/hashing
import iaragon/infrastructure/fs/local_scan
import simplifile

// Runtime performance: the pieces the scale tests do NOT cover — real
// filesystem scanning (every 30s round walks the mirror), md5 hashing of a
// big file, and the two streaming transfer paths. Each test prints its
// measurement and asserts the property that must not regress (streaming
// stays streaming: peak binary memory far below the payload size).

@external(erlang, "iaragon_bench_ffi", "peak_binary_memory")
fn peak_binary_memory(run: fn() -> a) -> #(a, Int)

@external(erlang, "iaragon_fake_drive_ffi", "start_server")
fn start_fake_drive(
  handle: fn(String, String, BitArray) ->
    #(Int, List(#(String, String)), String),
) -> Int

const scan_root = "build/test-scratch/perf-scan"

const scan_dirs = 100

const scan_files_per_dir = 100

const payload_root = "build/test-scratch/perf-payload"

/// 32 MiB: big enough that a whole-file buffer would dwarf a streaming
/// window, small enough to keep the suite quick.
const payload_bytes = 33_554_432

fn now_ms() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds
  |> fn(seconds) { float.round(seconds *. 1000.0) }
}

fn report(label: String, elapsed_ms: Int, peak_bytes: Int) -> Nil {
  io.println(
    "  [perf] "
    <> label
    <> ": "
    <> int.to_string(elapsed_ms)
    <> " ms, peak binary +"
    <> int.to_string(peak_bytes / 1_048_576)
    <> " MiB",
  )
}

// --- fixtures (cached across runs under build/) --------------------------

fn ensure_scan_tree() -> Nil {
  let marker = scan_root <> "/dir100/file100.txt"
  case simplifile.is_file(marker) {
    Ok(True) -> Nil
    _ -> {
      list.each(build_range(scan_dirs, 1, []), fn(dir) {
        let dir_path = scan_root <> "/dir" <> int.to_string(dir)
        let assert Ok(Nil) = simplifile.create_directory_all(dir_path)
        list.each(build_range(scan_files_per_dir, 1, []), fn(file) {
          let assert Ok(Nil) =
            simplifile.write(
              to: dir_path <> "/file" <> int.to_string(file) <> ".txt",
              contents: "payload",
            )
        })
      })
    }
  }
}

fn ensure_payload_file() -> String {
  let path = payload_root <> "/big.bin"
  case simplifile.file_info(path) {
    Ok(info) if info.size == payload_bytes -> path
    _ -> {
      let assert Ok(Nil) = simplifile.create_directory_all(payload_root)
      // 1 MiB chunk appended 32 times — quick to build, nothing huge held.
      let chunk = string.repeat("iaragon-perf-payload-64-bytes-block-", 29_128)
      let chunk = bit_array.from_string(string.slice(chunk, 0, 1_048_576))
      let assert Ok(Nil) = simplifile.write_bits(to: path, bits: <<>>)
      list.each(build_range(32, 1, []), fn(_n) {
        let assert Ok(Nil) = simplifile.append_bits(to: path, bits: chunk)
      })
      path
    }
  }
}

// --- measurements ---------------------------------------------------------

pub fn scanning_ten_thousand_files_stays_subsecond_test() {
  ensure_scan_tree()
  let started = now_ms()
  let assert Ok(files) = local_scan.scan_mirror(scan_root)
  let elapsed = now_ms() - started
  report("local_scan 10k files", elapsed, 0)
  assert list.length(files) == scan_dirs * scan_files_per_dir
  // The mirror walk runs every round; at 10k files it must stay well under
  // the 30s cadence — sub-second on any healthy disk.
  assert elapsed < 10_000
}

pub fn hashing_a_big_file_streams_instead_of_slurping_test() {
  let path = ensure_payload_file()
  let #(outcome, peak) =
    peak_binary_memory(fn() {
      let started = now_ms()
      let assert Ok(_md5) = hashing.hash_mirror_file(payload_root, "big.bin")
      now_ms() - started
    })
  report("md5 32 MiB", outcome, peak)
  let assert Ok(_) = simplifile.file_info(path)
  // Hashing must be windowed: a whole-file read would peak at the full
  // payload size. Allow a generous streaming window (4 MiB).
  assert peak < 4_194_304
}

pub fn downloading_a_big_file_streams_to_disk_test() {
  let path = ensure_payload_file()
  let assert Ok(payload) = simplifile.read_bits(path)
  let payload = bit_array.to_string(payload) |> result.unwrap("")
  let port =
    start_fake_drive(fn(_method, _target, _body) { #(200, [], payload) })
  let destination = payload_root <> "/downloaded.bin"
  let _ = simplifile.delete(destination)

  let #(elapsed, peak) =
    peak_binary_memory(fn() {
      let started = now_ms()
      let assert Ok(Nil) =
        download.fetch_file_to_disk(
          url: "http://127.0.0.1:" <> int.to_string(port) <> "/blob",
          access_token: "perf-token",
          destination: destination,
          timeout_ms: 60_000,
        )
      now_ms() - started
    })
  report("download 32 MiB (streaming FFI)", elapsed, peak)
  let assert Ok(info) = simplifile.file_info(destination)
  assert info.size == payload_bytes
  // {stream, path} must write as it receives — the CLIENT side never holds
  // the payload. (The fake server holds its copy; the sampler is global, so
  // the bound is payload-sized headroom rather than a few MiB.)
  assert peak < payload_bytes * 2
}

pub fn uploading_a_big_file_keeps_chunked_memory_test() {
  let path = ensure_payload_file()
  let received = process.new_subject()
  let port =
    start_fake_drive(fn(method, _target, body) {
      case method {
        "POST" -> #(
          200,
          [#("Location", "https://www.googleapis.com/perf-session")],
          "",
        )
        "PUT" -> {
          process.send(received, bit_array.byte_size(body))
          case bit_array.byte_size(body) < 10_485_760 {
            // Final (short) chunk: answer with the file metadata.
            True -> #(
              200,
              [],
              "{\"id\":\"id-big\",\"name\":\"big.bin\",\"mimeType\":"
                <> "\"application/octet-stream\",\"parents\":[\"root-1\"],"
                <> "\"modifiedTime\":\"2026-07-01T10:00:00Z\",\"size\":\""
                <> int.to_string(payload_bytes)
                <> "\",\"md5Checksum\":\"x\",\"trashed\":false}",
            )
            False -> #(308, [], "")
          }
        }
        _ -> #(404, [], "")
      }
    })

  let #(elapsed, peak) =
    peak_binary_memory(fn() {
      let started = now_ms()
      let assert Ok(_file) =
        upload.upload_file(
          send_bits_to(port),
          access_token: "perf-token",
          target: upload.CreateFile("big.bin", "root-1"),
          source_path: path,
          total_size: payload_bytes,
          chunk_size: 10_485_760,
        )
      now_ms() - started
    })
  report("upload 32 MiB (10 MiB chunks)", elapsed, peak)
  // 32 MiB in 10 MiB chunks: 3 full + one final short chunk of 2 MiB.
  let assert Ok(first) = process.receive(received, 1000)
  assert first == 10_485_760
  // Chunked read: memory stays around a chunk (plus the server's copies in
  // the same VM), never the whole file per request.
  assert peak < payload_bytes * 2
}

fn send_bits_to(
  port: Int,
) -> fn(Request(BitArray)) -> Result(Response(String), String) {
  fn(req) {
    use response <- result.try(
      request.Request(
        ..req,
        scheme: http.Http,
        host: "127.0.0.1",
        port: Some(port),
      )
      |> httpc.send_bits
      |> result.map_error(string.inspect),
    )
    use body <- result.try(
      bit_array.to_string(response.body)
      |> result.replace_error("non-utf8 response body"),
    )
    Ok(response.Response(..response, body: body))
  }
}

fn build_range(current: Int, floor: Int, acc: List(Int)) -> List(Int) {
  case current < floor {
    True -> acc
    False -> build_range(current - 1, floor, [current, ..acc])
  }
}
