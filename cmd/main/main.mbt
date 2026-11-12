///|
#borrow(path)
extern "C" fn io_read(path : Bytes, cap : Int32) -> Bytes = "mbsd_read"

///|
#borrow(a, b, out)
extern "C" fn io_check(a : Bytes, b : Bytes, out : Bytes) -> Int32 = "mbsd_output_check"

///|
#borrow(path, data)
extern "C" fn io_deliver(path : Bytes, data : Bytes) -> Int32 = "mbsd_deliver"

///|
extern "C" fn io_error() -> Bytes = "mbsd_io_error"

///|
extern "C" fn io_failed() -> Int32 = "mbsd_io_failed"

///|
#borrow(text)
extern "C" fn stderr(text : Bytes) -> Unit = "mbsd_stderr"

///|
fn path_bytes(path : String) -> Bytes {
  @utf8.encode(path[:]) + b"\x00"
}

///|
fn failure(text : String) -> Unit {
  stderr(@utf8.encode(("moonbsdiff: " + text + "\n")[:]))
  @env.exit(1)
}

///|
fn read_input(operation : String, path : String, cap : Int64) -> Bytes {
  let value = io_read(path_bytes(path), cap.to_int())
  if io_failed() != 0 {
    failure(operation + " '" + path + "': " + @utf8.decode_lossy(io_error()[:]))
  }
  value
}

///|
extern "C" fn native_arg_count() -> Int32 = "mbsd_arg_count"

///|
extern "C" fn native_arg(index : Int32) -> String = "mbsd_arg"

///|
fn cli_args() -> Array[String] {
  let count = native_arg_count()
  if count == -1 {
    @env.args()
  } else if count < 0 {
    failure("command-line arguments: " + @utf8.decode_lossy(io_error()[:]))
    []
  } else {
    Array::makei(count, i => native_arg(i))
  }
}

///|
fn main {
  let args = cli_args()
  if args.length() == 2 && args[1] == "--help" {
    println("moonbsdiff diff OLD_FILE NEW_FILE PATCH_FILE")
    println("moonbsdiff patch OLD_FILE PATCH_FILE OUTPUT_FILE")
    println("moonbsdiff --help | --version")
    println(
      "Binary files only. Existing outputs (including links) are never replaced.",
    )
    println(
      "diff: old/new/output 65536 bytes, patch 131072, raw 262144, 4096 controls; sort/match 8388608 each.",
    )
    println(
      "patch: old/output 1048576 bytes, patch 131072, decoded 2097152, 16384 controls.",
    )
    println(
      "Linux output requires O_TMPFILE and /proc; no unsafe fallback. No durability guarantee.",
    )
    println(
      "Exit codes: 0 success, 2 arguments, 1 operation failure. BSDIFF40 does not identify the old file.",
    )
    @env.exit(0)
  }
  if args.length() == 2 && args[1] == "--version" {
    println("moonbsdiff \{cli_version}")
    @env.exit(0)
  }
  if args.length() != 5 || (args[1] != "diff" && args[1] != "patch") {
    stderr(
      b"moonbsdiff: expected diff OLD NEW PATCH or patch OLD PATCH OUTPUT; use --help\n",
    )
    @env.exit(2)
  }
  let operation = args[1]
  let first = args[2]
  let second = args[3]
  let output = args[4]
  if io_check(path_bytes(first), path_bytes(second), path_bytes(output)) == 0 {
    failure(
      operation +
      " output '" +
      output +
      "' (inputs '" +
      first +
      "', '" +
      second +
      "'): " +
      @utf8.decode_lossy(io_error()[:]),
    )
  }
  let limits = if operation == "diff" {
    @moonbsdiff.Limits::for_diff()
  } else {
    {
      ..@moonbsdiff.Limits::for_apply(),
      max_patch_bytes: @moonbsdiff.Limits::for_diff().max_patch_bytes,
    }
  }
  let old = read_input(operation + " read old", first, limits.max_old_bytes)
  let other = read_input(
    operation + " read " + (if operation == "diff" { "new" } else { "patch" }),
    second,
    if operation == "diff" {
      limits.max_new_bytes
    } else {
      limits.max_patch_bytes
    },
  )
  let result = if operation == "diff" {
    @moonbsdiff.diff(old, other, limits)
  } else {
    @moonbsdiff.apply(old, other, limits)
  }
  let value = match result {
    Ok(v) => v
    Err(e) => {
      failure(
        operation +
        " inputs '" +
        first +
        "', '" +
        second +
        "' -> '" +
        output +
        "': " +
        @debug.to_string(e),
      )
      b""
    }
  }
  if io_deliver(path_bytes(output), value) == 0 {
    failure(
      operation +
      " write/deliver '" +
      output +
      "': " +
      @utf8.decode_lossy(io_error()[:]),
    )
  }
}
