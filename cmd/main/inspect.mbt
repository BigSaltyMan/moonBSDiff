///|
fn json_range(start : Int64, length : Int64) -> @json.Json {
  @json.Json::object({
    "start_bytes": @json.Json::string("\{start}"),
    "length_bytes": @json.Json::string("\{length}"),
  })
}

///|
priv struct DeepInspectStats {
  control_count : Int64
  diff_bytes : Int64
  extra_bytes : Int64
  expanded_bytes : Int64
}

///|
fn consume_inspect_bytes(
  reader : @bzip2.StreamReader,
  size : Int64,
  block : String,
) -> Unit raise {
  let mut remaining = size
  while remaining > 0L {
    let chunk = reader.read(Int64::min(4096L, remaining).to_int())
    stream_require(chunk.length() > 0, "Inspect TruncatedData: " + block)
    remaining -= chunk.length().to_int64()
  }
}

///|
fn inspect_deep(
  patch : Bytes,
  info : @moonbsdiff.PatchInfo,
  limits : @moonbsdiff.Limits,
) -> DeepInspectStats raise {
  stream_require(
    info.new_bytes <= limits.max_output_bytes,
    "Inspect ResourceLimitExceeded: max_output_bytes value=\{info.new_bytes} limit=\{limits.max_output_bytes}",
  )
  let budget = @bzip2.Budget::{
    remaining: limits.max_decompressed_bytes,
    emitted: 0L,
  }
  let (control, delta, extra) = open_patch_streams(info, limits, budget, (
    start,
    length,
  ) => {
    // The envelope has already validated both end positions against the
    // Int-indexable patch buffer. The reader requests bounded chunks.
    let mut at = start.to_int()
    let end = (start + length).to_int()
    fn() {
      let next = at + Int32::min(4096, end - at)
      let chunk = patch[at:next].to_owned()
      at = next
      chunk
    }
  })
  let mut control_count = 0L
  let mut diff_bytes = 0L
  let mut extra_bytes = 0L
  let mut oldpos = 0L
  let mut remaining = info.new_bytes
  while remaining > 0L {
    let (x, y, z) = read_stream_control(control, control_count, limits)
    control_count += 1L
    check_stream_output(x, remaining, "diff")
    let oldend = stream_add(oldpos, x)
    consume_inspect_bytes(delta, x, "diff")
    diff_bytes += x
    remaining -= x
    check_stream_output(y, remaining, "extra")
    consume_inspect_bytes(extra, y, "extra")
    extra_bytes += y
    remaining -= y
    oldpos = stream_add(oldend, z)
  }
  finish_patch_streams(control, delta, extra, () => ())
  // Verified EOF proves every byte reserved by the decoders was consumed.
  { control_count, diff_bytes, extra_bytes, expanded_bytes: budget.emitted, }
}

///|
fn inspect_command(config : CliConfig) -> Unit {
  let path = config.files[0]
  let cap = config.limits.max_patch_bytes
  let patch = read_input(
    "inspect read patch (max_patch_bytes=\{cap} bytes)",
    path,
    cap,
  )
  let info = match @moonbsdiff.inspect_header(patch, cap) {
    Ok(value) => value
    Err(e) => {
      failure("inspect '" + path + "': " + @debug.to_string(e))
      return
    }
  }
  let stats = if config.deep {
    Some(inspect_deep(patch, info, config.limits)) catch {
      StreamError(message) => {
        failure("inspect deep '" + path + "': " + message)
        return
      }
      e => {
        failure("inspect deep '" + path + "': " + @debug.to_string(e))
        return
      }
    }
  } else {
    None
  }
  let validation = if stats is Some(_) { "deep" } else { "header-only" }
  // Serialize the complete success result only after all structural checks pass.
  if config.json {
    let fields : Map[String, @json.Json] = {
      "schema_version": @json.Json::number(1.0),
      "format": @json.Json::string("BSDIFF40"),
      "patch_path": @json.Json::string(path),
      "patch_bytes": @json.Json::string("\{info.patch_bytes}"),
      "new_bytes": @json.Json::string("\{info.new_bytes}"),
      "validation": @json.Json::string(validation),
      "compressed_ranges": @json.Json::object({
        "control": json_range(info.control_start, info.control_length),
        "diff": json_range(info.diff_start, info.diff_length),
        "extra": json_range(info.extra_start, info.extra_length),
      }),
    }
    let checked = @json.Json::string(
      if stats is Some(_) {
        "passed"
      } else {
        "not-checked"
      },
    )
    let checks : Map[String, @json.Json] = {
      "compressed_streams": checked,
      "crc": checked,
      "control_instructions": checked,
      "restoration": @json.Json::string("not-checked"),
      "identity": @json.Json::string("not-checked"),
    }
    if stats is Some(value) {
      checks["complete_consumption"] = checked
      fields["control_count"] = @json.Json::string("\{value.control_count}")
      fields["diff_bytes"] = @json.Json::string("\{value.diff_bytes}")
      fields["extra_bytes"] = @json.Json::string("\{value.extra_bytes}")
      fields["expanded_bytes"] = @json.Json::string("\{value.expanded_bytes}")
    }
    fields["checks"] = @json.Json::object(checks)
    println(@json.Json::object(fields).stringify())
  } else {
    println("Format: BSDIFF40")
    println("Patch bytes: \{info.patch_bytes}")
    println("Declared restored bytes: \{info.new_bytes}")
    println(
      "Control compressed range: start=\{info.control_start} length=\{info.control_length} bytes",
    )
    println(
      "Diff compressed range: start=\{info.diff_start} length=\{info.diff_length} bytes",
    )
    println(
      "Extra compressed range: start=\{info.extra_start} length=\{info.extra_length} bytes",
    )
    println("Validation: \{validation}")
    if stats is Some(value) {
      println("Control count: \{value.control_count}")
      println("Diff bytes: \{value.diff_bytes}")
      println("Extra bytes: \{value.extra_bytes}")
      println("Expanded bytes: \{value.expanded_bytes}")
      println("Compressed streams / CRC: passed")
      println("Control instructions: passed")
      println("Complete consumption: passed")
    } else {
      println("Compressed streams / CRC: not checked")
      println("Control instructions: not checked")
    }
    println("Restoration: not checked")
    println("Identity: not checked")
  }
}
