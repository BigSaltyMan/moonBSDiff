///|
fn json_range(start : Int64, length : Int64) -> @json.Json {
  @json.Json::object({
    "start_bytes": @json.Json::string("\{start}"),
    "length_bytes": @json.Json::string("\{length}"),
  })
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
  let (info, stats) = if config.deep {
    match @moonbsdiff.inspect_deep(patch, config.limits) {
      Ok(value) => (value.header, Some(value))
      Err(e) => {
        failure("inspect deep '" + path + "': " + @debug.to_string(e))
        return
      }
    }
  } else {
    match @moonbsdiff.inspect_header(patch, cap) {
      Ok(value) => (value, None)
      Err(e) => {
        failure("inspect '" + path + "': " + @debug.to_string(e))
        return
      }
    }
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
