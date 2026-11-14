///|
#borrow(path)
extern "C" fn io_read(path : Bytes, cap : Int32) -> Bytes = "mbsd_read"

///|
#borrow(a, b, out)
extern "C" fn io_check(a : Bytes, b : Bytes, out : Bytes) -> Int32 = "mbsd_output_check"

///|
#borrow(a, b)
extern "C" fn io_pair_check(a : Bytes, b : Bytes) -> Int32 = "mbsd_pair_check"

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
fn print_help() -> Unit {
  println("moonbsdiff diff OLD_FILE NEW_FILE PATCH_FILE")
  println("moonbsdiff patch OLD_FILE PATCH_FILE OUTPUT_FILE")
  println("moonbsdiff --help | --version")
  println(
    "moonbsdiff verify --manifest MANIFEST_FILE [LIMITS] OLD_FILE PATCH_FILE",
  )
  println(
    "moonbsdiff patch --manifest MANIFEST_FILE [LIMITS] OLD_FILE PATCH_FILE OUTPUT_FILE",
  )
  println(
    "Manifest input: at most 16384 bytes, schema 1, no duplicate/unknown keys. Verify restores in memory, never writes output.",
  )

  println(
    "--manifest MANIFEST_FILE: diff writes; patch/verify read and validate the SHA-256 JSON manifest.",
  )
  println(
    "Patch then manifest are delivered without replacement; two-file delivery is not atomic.",
  )
  println("moonbsdiff inspect [--json] [--max-patch-bytes VALUE] PATCH_FILE")
  println(
    "inspect is header-only: streams/CRC, controls, restoration and identity are not checked.",
  )
  println("With options: moonbsdiff diff|patch [OPTIONS] FILE FILE FILE")
  println(
    "Display only: moonbsdiff diff|patch [OPTIONS] --show-limits (no files)",
  )
  println(
    "Options precede all paths; -- ends options and allows leading '-' paths.",
  )
  println(
    "Byte options (diff/patch): --max-old-bytes, --max-new-bytes, --max-output-bytes, --max-patch-bytes, --max-expanded-bytes VALUE",
  )
  println(
    "Bytes: positive ASCII decimal with optional case-sensitive B, KiB or MiB; no spaces or signs.",
  )
  println(
    "Count (diff/patch): --max-controls VALUE. Diff only: --max-sort-work, --max-match-work VALUE.",
  )
  println(
    "Counts/work: positive decimal integers, no units. Each option occurs at most once; use separate values, not '='.",
  )
  println(
    "Expanded bytes: raw control/diff/extra for diff; cumulative decoded bytes for patch.",
  )
  println(
    "New and output caps constrain the target independently; patch bytes have a separate cap.",
  )
  println(
    "Match work includes generation; increasing one cap does not increase any other.",
  )

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
}

///|
// ASCII-only positive decimals; reserve both decimal and unit arithmetic before use.
fn parse_limit(text : String, bytes : Bool) -> Result[Int64, String] {
  let raw = @utf8.encode(text[:])
  let mut end = raw.length()
  let mut multiplier = 1L
  if bytes &&
    end >= 3 &&
    raw[end - 2].to_int() == 105 &&
    raw[end - 1].to_int() == 66 {
    if raw[end - 3].to_int() == 75 {
      multiplier = 1024L
      end = end - 3
    } else if raw[end - 3].to_int() == 77 {
      multiplier = 1048576L
      end = end - 3
    }
  } else if bytes && end >= 1 && raw[end - 1].to_int() == 66 {
    end = end - 1
  }
  if end == 0 {
    return Err("expected a positive decimal value")
  }
  let mut value = 0L
  for i = 0; i < end; i = i + 1 {
    let digit = raw[i].to_int() - 48
    if digit < 0 || digit > 9 {
      return Err(
        "expected ASCII digits" +
        (if bytes { " with optional B, KiB or MiB" } else { " without units" }),
      )
    }
    if value > (9223372036854775807L - digit.to_int64()) / 10L {
      return Err("decimal value overflows Int64")
    }
    value = value * 10L + digit.to_int64()
  }
  if value == 0L {
    return Err("value must be positive; zero is not unlimited")
  }
  if value > 9223372036854775807L / multiplier {
    return Err("unit conversion overflows Int64")
  }
  Ok(value * multiplier)
}

///|
struct CliConfig {
  operation : String
  limits : @moonbsdiff.Limits
  show : Bool
  json : Bool
  manifest : String?
  files : Array[String]
}

///|
fn leading_dash(text : String) -> Bool {
  let raw = @utf8.encode(text[:])
  raw.length() > 0 && raw[0].to_int() == 45
}

///|
fn parse_cli(args : Array[String]) -> Result[CliConfig, String] {
  if args.length() < 2 ||
    (
      args[1] != "diff" &&
      args[1] != "patch" &&
      args[1] != "inspect" &&
      args[1] != "verify"
    ) {
    return Err(
      "expected diff OLD NEW PATCH, patch OLD PATCH OUTPUT, inspect PATCH, or verify --manifest MANIFEST OLD PATCH; use --help",
    )
  }
  let operation = args[1]
  let mut limits = if operation == "diff" {
    @moonbsdiff.Limits::for_diff()
  } else {
    {
      ..@moonbsdiff.Limits::for_apply(),
      max_patch_bytes: @moonbsdiff.Limits::for_diff().max_patch_bytes,
    }
  }
  let seen : Array[String] = []
  let mut show = false
  let mut json = false
  let mut manifest : String? = None
  let mut escaped = false
  let mut i = 2
  while i < args.length() {
    let option = args[i]
    if option == "--" {
      escaped = true
      i = i + 1
      break
    }
    if !leading_dash(option) {
      break
    }
    if operation == "inspect" &&
      option != "--json" &&
      option != "--max-patch-bytes" {
      return Err(option + " is not applicable to inspect")
    }
    let bytes = match option {
      "--manifest" => false
      "--json" => {
        if operation != "inspect" {
          return Err("--json is only applicable to inspect")
        }
        false
      }
      "--show-limits" => {
        if operation == "verify" {
          return Err("--show-limits is not applicable to verify")
        }
        false
      }
      "--max-old-bytes"
      | "--max-new-bytes"
      | "--max-output-bytes"
      | "--max-patch-bytes"
      | "--max-expanded-bytes" => true
      "--max-controls" => false
      "--max-sort-work" | "--max-match-work" => {
        if operation != "diff" {
          return Err(option + " is not applicable to " + operation)
        }
        false
      }
      _ => return Err("unknown option: " + option)
    }
    if seen.contains(option) {
      return Err("duplicate option: " + option)
    }
    seen.push(option)
    if option == "--json" {
      json = true
      i = i + 1
      continue
    }
    if option == "--show-limits" {
      show = true
      i = i + 1
      continue
    }
    if i + 1 >= args.length() {
      return Err("missing value for " + option)
    }
    if option == "--manifest" {
      let path = args[i + 1]
      if path.length() == 0 || leading_dash(path) {
        return Err(
          "--manifest requires a nonempty path value; use ./ for a leading '-' name",
        )
      }
      manifest = Some(path)
      i = i + 2
      continue
    }
    let value = match parse_limit(args[i + 1], bytes) {
      Ok(v) => v
      Err(e) => return Err(option + ": " + e)
    }
    limits = match option {
      "--max-old-bytes" => { ..limits, max_old_bytes: value, }
      "--max-new-bytes" => { ..limits, max_new_bytes: value, }
      "--max-output-bytes" => { ..limits, max_output_bytes: value, }
      "--max-patch-bytes" => { ..limits, max_patch_bytes: value, }
      "--max-expanded-bytes" => { ..limits, max_decompressed_bytes: value, }
      "--max-controls" => { ..limits, max_control_instructions: value, }
      "--max-sort-work" => { ..limits, max_sort_work: value, }
      "--max-match-work" => { ..limits, max_match_work: value, }
      _ => limits
    }
    i = i + 2
  }
  let files : Array[String] = []
  while i < args.length() {
    if !escaped && leading_dash(args[i]) {
      return Err(
        "options must precede file arguments; use -- before paths starting with '-'",
      )
    }
    files.push(args[i])
    i = i + 1
  }
  if show && files.length() != 0 {
    return Err(
      "--show-limits accepts no file arguments and never executes an operation",
    )
  }
  if show && manifest is Some(_) {
    return Err("--manifest cannot be combined with --show-limits")
  }
  if operation == "verify" && manifest is None {
    return Err("verify requires --manifest MANIFEST_FILE")
  }
  let expected = if operation == "inspect" {
    1
  } else if operation == "verify" {
    2
  } else {
    3
  }
  if !show && files.length() != expected {
    return Err("expected exactly \{expected} file arguments; use --help")
  }
  match limits.validate() {
    Ok(_) => ()
    Err(e) => return Err(@debug.to_string(e))
  }
  Ok({ operation, limits, show, json, manifest, files, })
}

///|
fn show_limits(config : CliConfig) -> Unit {
  let l = config.limits
  println("operation: \{config.operation}")
  println("max_old_bytes: \{l.max_old_bytes} bytes")
  println("max_new_bytes: \{l.max_new_bytes} bytes")
  println(
    "max_output_bytes: \{l.max_output_bytes} bytes (target buffer; patch has separate cap)",
  )
  println("max_patch_bytes: \{l.max_patch_bytes} bytes")
  let meaning = if config.operation == "diff" {
    "raw control + diff + extra"
  } else {
    "cumulative decoded control + diff + extra"
  }
  println(
    "max_decompressed_bytes: \{l.max_decompressed_bytes} bytes (\{meaning})",
  )
  println(
    "max_control_instructions: \{l.max_control_instructions} instructions",
  )
  if config.operation == "diff" {
    println("max_sort_work: \{l.max_sort_work} work units")
    println(
      "max_match_work: \{l.max_match_work} work units (matching + generation)",
    )
  } else {
    println("max_sort_work: unused by patch (no generation budget)")
    println("max_match_work: unused by patch (no generation budget)")
  }
}

///|
fn main {
  let args = cli_args()
  if args.length() == 2 && args[1] == "--help" {
    print_help()
    @env.exit(0)
  }
  if args.length() == 2 && args[1] == "--version" {
    println("moonbsdiff \{cli_version}")
    @env.exit(0)
  }
  let config = match parse_cli(args) {
    Ok(v) => v
    Err(e) => {
      stderr(@utf8.encode(("moonbsdiff: " + e + "\n")[:]))
      @env.exit(2)
      return
    }
  }
  if config.show {
    show_limits(config)
    @env.exit(0)
  }
  if config.operation == "inspect" {
    inspect_command(config)
    return
  }
  if config.operation == "verify" {
    verified_restore(config) |> ignore
    println(
      "Verification succeeded: manifest, inputs and restored content match (not publisher authentication).",
    )
    return
  }
  let operation = config.operation
  let limits = config.limits
  let first = config.files[0]
  let second = config.files[1]
  let output = config.files[2]
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
  if operation == "patch" && config.manifest is Some(manifest_path) {
    if io_check(
        path_bytes(first),
        path_bytes(manifest_path),
        path_bytes(output),
      ) ==
      0 {
      failure(
        "patch output conflicts with input/manifest: " +
        @utf8.decode_lossy(io_error()[:]),
      )
    }
    let restored = verified_restore(config)
    if io_deliver(path_bytes(output), restored) == 0 {
      failure(
        "patch verified write/deliver '" +
        output +
        "': " +
        @utf8.decode_lossy(io_error()[:]),
      )
    }
    return
  }
  if operation == "diff" && config.manifest is Some(manifest_path) {
    if io_check(
        path_bytes(first),
        path_bytes(second),
        path_bytes(manifest_path),
      ) ==
      0 {
      failure(
        "manifest output '" +
        manifest_path +
        "': " +
        @utf8.decode_lossy(io_error()[:]),
      )
    }
    if io_pair_check(path_bytes(output), path_bytes(manifest_path)) == 0 {
      failure(
        "patch/manifest output conflict: " + @utf8.decode_lossy(io_error()[:]),
      )
    }
  }
  // All native caps were validated as positive Int-indexable bytes before any IO.
  let old = read_input(
    operation + " read old (max_old_bytes=\{limits.max_old_bytes} bytes)",
    first,
    limits.max_old_bytes,
  )
  let other = read_input(
    operation +
    " read " +
    (if operation == "diff" {
      "new (max_new_bytes=\{limits.max_new_bytes} bytes)"
    } else {
      "patch (max_patch_bytes=\{limits.max_patch_bytes} bytes)"
    }),
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
  // All hashes refer to these exact buffers; no path is reopened for hashing.
  let manifest_data = match config.manifest {
    Some(_) => Some(make_manifest(old, other, value))
    None => None
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
  if config.manifest is Some(manifest_path) && manifest_data is Some(data) {
    if io_deliver(path_bytes(manifest_path), data) == 0 {
      failure(
        "patch delivered to '" +
        output +
        "'; manifest not completed at '" +
        manifest_path +
        "': " +
        @utf8.decode_lossy(io_error()[:]) +
        "; no rollback attempted",
      )
    }
  }
}
