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
  let info = match @moonbsdiff.inspect_header(patch, cap) {
    Ok(value) => value
    Err(e) => {
      failure("inspect '" + path + "': " + @debug.to_string(e))
      return
    }
  }
  // Serialize the complete success result only after all structural checks pass.
  if config.json {
    let document = @json.Json::object({
      "schema_version": @json.Json::number(1.0),
      "format": @json.Json::string("BSDIFF40"),
      "patch_path": @json.Json::string(path),
      "patch_bytes": @json.Json::string("\{info.patch_bytes}"),
      "new_bytes": @json.Json::string("\{info.new_bytes}"),
      "validation": @json.Json::string("header-only"),
      "compressed_ranges": @json.Json::object({
        "control": json_range(info.control_start, info.control_length),
        "diff": json_range(info.diff_start, info.diff_length),
        "extra": json_range(info.extra_start, info.extra_length),
      }),
      "checks": @json.Json::object({
        "compressed_streams": @json.Json::string("not-checked"),
        "crc": @json.Json::string("not-checked"),
        "control_instructions": @json.Json::string("not-checked"),
        "restoration": @json.Json::string("not-checked"),
        "identity": @json.Json::string("not-checked"),
      }),
    })
    println(document.stringify())
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
    println("Validation: header-only")
    println("Compressed streams / CRC: not checked")
    println("Control instructions: not checked")
    println("Restoration: not checked")
    println("Identity: not checked")
  }
}
