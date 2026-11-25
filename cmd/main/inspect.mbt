///|
fn json_range(start : Int64, length : Int64) -> @json.Json {
  @json.Json::object({
    "start_bytes": @json.Json::string("\{start}"),
    "length_bytes": @json.Json::string("\{length}"),
  })
}

///|
fn risk_level_label(level : @moonbsdiff.RiskLevel) -> String {
  match level {
    @moonbsdiff.Low => "low"
    @moonbsdiff.Elevated => "elevated"
    @moonbsdiff.High => "high"
  }
}

///|
fn inspect_analyze_command(
  config : CliConfig,
  path : String,
  patch : Bytes,
) -> Unit {
  let analysis = match
    @moonbsdiff.analyze_patch(patch, {
      ..config.limits,
      max_new_bytes: config.limits.max_output_bytes,
    }) {
    Ok(value) => value
    Err(e) => {
      failure("inspect analyze '" + path + "': " + @debug.to_string(e))
      return
    }
  }
  let info = analysis.deep.header
  if config.json {
    let flags : Array[@json.Json] = []
    for flag in analysis.risk_flags {
      flags.push(
        @json.Json::object({
          "code": @json.Json::string(flag.code),
          "severity": @json.Json::string(risk_level_label(flag.severity)),
          "detail": @json.Json::string(flag.detail),
        }),
      )
    }
    let samples : Array[@json.Json] = []
    for sample in analysis.sample_controls {
      samples.push(
        @json.Json::object({
          "index": @json.Json::string("\{sample.index}"),
          "add_bytes": @json.Json::string("\{sample.add_bytes}"),
          "extra_bytes": @json.Json::string("\{sample.extra_bytes}"),
          "seek_offset": @json.Json::string("\{sample.seek_offset}"),
        }),
      )
    }
    let req = analysis.required_limits
    let doc = @json.Json::object({
      "schema_version": @json.Json::number(1.0),
      "format": @json.Json::string("BSDIFF40"),
      "patch_path": @json.Json::string(path),
      "validation": @json.Json::string("analyze"),
      "header": @json.Json::object({
        "patch_bytes": @json.Json::string("\{info.patch_bytes}"),
        "new_bytes": @json.Json::string("\{info.new_bytes}"),
        "control_length": @json.Json::string("\{info.control_length}"),
        "diff_length": @json.Json::string("\{info.diff_length}"),
        "extra_length": @json.Json::string("\{info.extra_length}"),
      }),
      "deep": @json.Json::object({
        "control_count": @json.Json::string("\{analysis.deep.control_count}"),
        "diff_bytes": @json.Json::string("\{analysis.deep.diff_bytes}"),
        "extra_bytes": @json.Json::string("\{analysis.deep.extra_bytes}"),
        "expanded_bytes": @json.Json::string("\{analysis.deep.expanded_bytes}"),
      }),
      "ratios": @json.Json::object({
        "expansion_ratio_permille": @json.Json::string(
          "\{analysis.expansion_ratio_permille}",
        ),
        "diff_share_permille": @json.Json::string(
          "\{analysis.diff_share_permille}",
        ),
        "extra_share_permille": @json.Json::string(
          "\{analysis.extra_share_permille}",
        ),
        "patch_to_output_permille": @json.Json::string(
          "\{analysis.patch_to_output_permille}",
        ),
      }),
      "seeks": @json.Json::object({
        "negative_seek_count": @json.Json::string(
          "\{analysis.negative_seek_count}",
        ),
        "max_abs_seek": @json.Json::string("\{analysis.max_abs_seek}"),
      }),
      "risk_level": @json.Json::string(risk_level_label(analysis.risk_level)),
      "risk_flags": @json.Json::array(flags),
      "required_limits": @json.Json::object({
        "max_patch_bytes": @json.Json::string("\{req.max_patch_bytes}"),
        "max_new_bytes": @json.Json::string("\{req.max_new_bytes}"),
        "max_output_bytes": @json.Json::string("\{req.max_output_bytes}"),
        "max_decompressed_bytes": @json.Json::string(
          "\{req.max_decompressed_bytes}",
        ),
        "max_control_instructions": @json.Json::string(
          "\{req.max_control_instructions}",
        ),
      }),
      "sample_controls": @json.Json::array(samples),
    })
    println(doc.stringify())
  } else {
    println("Format: BSDIFF40")
    println("Validation: analyze")
    println("Patch bytes: \{info.patch_bytes}")
    println("Declared restored bytes: \{info.new_bytes}")
    println(
      "Compressed lengths: control=\{info.control_length} diff=\{info.diff_length} extra=\{info.extra_length} total=\{analysis.total_compressed_bytes} bytes",
    )
    println("Control count: \{analysis.deep.control_count}")
    println("Diff bytes: \{analysis.deep.diff_bytes}")
    println("Extra bytes: \{analysis.deep.extra_bytes}")
    println("Expanded bytes: \{analysis.deep.expanded_bytes}")
    println("Expansion ratio: \{analysis.expansion_ratio_permille} permille")
    println("Diff share: \{analysis.diff_share_permille} permille")
    println("Extra share: \{analysis.extra_share_permille} permille")
    println(
      "Patch-to-output ratio: \{analysis.patch_to_output_permille} permille",
    )
    println(
      "Negative seeks: \{analysis.negative_seek_count} (max_abs_seek=\{analysis.max_abs_seek})",
    )
    println("Risk level: \{risk_level_label(analysis.risk_level)}")
    if analysis.risk_flags.length() == 0 {
      println("Risk flags: none")
    } else {
      println("Risk flags: \{analysis.risk_flags.length()}")
      for flag in analysis.risk_flags {
        println(
          "  - [\{risk_level_label(flag.severity)}] \{flag.code}: \{flag.detail}",
        )
      }
    }
    let req = analysis.required_limits
    println(
      "Required limits: max_patch_bytes=\{req.max_patch_bytes} max_new_bytes=\{req.max_new_bytes} max_output_bytes=\{req.max_output_bytes} max_decompressed_bytes=\{req.max_decompressed_bytes} max_control_instructions=\{req.max_control_instructions}",
    )
    println("Sample controls: \{analysis.sample_controls.length()}")
    for sample in analysis.sample_controls {
      println(
        "  #\{sample.index}: add=\{sample.add_bytes} extra=\{sample.extra_bytes} seek=\{sample.seek_offset}",
      )
    }
  }
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
  if config.analyze {
    inspect_analyze_command(config, path, patch)
    return
  }
  let (info, stats) = if config.deep {
    match
      @moonbsdiff.inspect_deep(patch, {
        ..config.limits,
        max_new_bytes: config.limits.max_output_bytes,
      }) {
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
