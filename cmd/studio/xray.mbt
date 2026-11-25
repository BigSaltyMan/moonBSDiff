///|
let xray_preset_cache : Map[String, Bytes] = Map([])

///|
fn build_xray_preset_patch(preset_name : String) -> Bytes? {
  match xray_preset_cache.get(preset_name) {
    Some(cached) => return Some(cached)
    None => ()
  }
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let patch_opt : Bytes? = match preset_name {
    "healthy_update" => {
      let old_arr = structured_firmware_image(8192, 0x7001U)
      let new_arr = mutate_slice(old_arr, 2400, prng_bytes(32, 0x7002U))
      let new_arr2 = mutate_slice(new_arr, 6000, b"MOONBSDIFF-0.7.0-OK!")
      Some(
        @moonbsdiff.diff(
          Bytes::from_array(old_arr),
          Bytes::from_array(new_arr2),
          diff_limits,
        ).unwrap(),
      )
    }
    "fastpath_prefix_suffix" => {
      let pre = prng_bytes(2048, 0x7101U)
      let suf = prng_bytes(2048, 0x7102U)
      let ins = b"FASTPATH-MID-EDIT-0.7.0!"
      let fast_limits = { ..diff_limits, max_sort_work: 1L, }
      Some(@moonbsdiff.diff(pre + suf, pre + ins + suf, fast_limits).unwrap())
    }
    "decompression_bomb" => {
      // Real tiny BSDIFF40 patch (~140 B) whose bzip2 diff stream expands to 100 KiB (>700x!).
      let zeros = Bytes::make(100000, b'\x00')
      let generous_diff : @moonbsdiff.Limits = {
        ..diff_limits,
        max_old_bytes: 131072L,
        max_new_bytes: 131072L,
        max_output_bytes: 131072L,
        max_decompressed_bytes: 262144L,
        max_sort_work: 1L,
      }
      Some(@moonbsdiff.diff(zeros, zeros, generous_diff).unwrap())
    }
    "incompressible_random" => {
      let old = prng_bytes(1024, 0x8101U)
      let new_b = prng_bytes(1024, 0x8102U)
      Some(@moonbsdiff.diff(old, new_b, diff_limits).unwrap())
    }
    "truncated_corrupt" => {
      let old_arr = structured_firmware_image(2048, 0x7201U)
      let new_arr = mutate_slice(old_arr, 512, b"CORRUPT-DEMO-TRUNCATED")
      let full_patch = @moonbsdiff.diff(
        Bytes::from_array(old_arr),
        Bytes::from_array(new_arr),
        diff_limits,
      ).unwrap()
      let cut = if full_patch.length() > 64 {
        full_patch.length() - 24
      } else {
        full_patch.length() / 2
      }
      Some(full_patch[:cut].to_owned())
    }
    "reordered_blocks" => {
      // Reversed distinct 48-byte blocks demonstrating negative seeks & multiple controls.
      let blocks : Array[Bytes] = []
      for i in 0..<24 {
        blocks.push(prng_bytes(48, 0x9000U + i.reinterpret_as_uint()))
      }
      let old_arr : Array[Byte] = []
      let new_arr : Array[Byte] = []
      for i in 0..<blocks.length() {
        for b in blocks[i] {
          old_arr.push(b)
        }
        for b in blocks[blocks.length() - 1 - i] {
          new_arr.push(b)
        }
      }
      Some(
        @moonbsdiff.diff(
          Bytes::from_array(old_arr),
          Bytes::from_array(new_arr),
          diff_limits,
        ).unwrap(),
      )
    }
    _ => None
  }
  match patch_opt {
    Some(p) => {
      xray_preset_cache[preset_name] = p
      Some(p)
    }
    None => None
  }
}

///|
fn limits_for_preset(limit_preset : String) -> @moonbsdiff.Limits {
  let base = @moonbsdiff.Limits::for_apply()
  match limit_preset {
    "tight" | "strict" =>
      {
        ..base,
        max_patch_bytes: 65536L,
        max_new_bytes: 131072L,
        max_output_bytes: 131072L,
        max_decompressed_bytes: 8192L,
        max_control_instructions: 512L,
      }
    "balanced" =>
      {
        ..base,
        max_patch_bytes: 131072L,
        max_new_bytes: 262144L,
        max_output_bytes: 262144L,
        max_decompressed_bytes: 262144L,
        max_control_instructions: 4096L,
      }
    _ => base
  }
}

///|
fn build_required_snippets(req : @moonbsdiff.Limits) -> (String, String) {
  let mbt = "let limits : @moonbsdiff.Limits = {\n" +
    "  ..@moonbsdiff.Limits::for_apply(),\n" +
    "  max_patch_bytes: \{req.max_patch_bytes}L,\n" +
    "  max_new_bytes: \{req.max_new_bytes}L,\n" +
    "  max_output_bytes: \{req.max_output_bytes}L,\n" +
    "  max_decompressed_bytes: \{req.max_decompressed_bytes}L,\n" +
    "  max_control_instructions: \{req.max_control_instructions}L,\n" +
    "}"
  let cli = "moonbsdiff inspect --deep" +
    " --max-patch-bytes \{req.max_patch_bytes}" +
    " --max-output-bytes \{req.max_output_bytes}" +
    " --max-decompressed-bytes \{req.max_decompressed_bytes}" +
    " --max-control-instructions \{req.max_control_instructions} update.patch"
  (mbt, cli)
}

///|
fn analyze_patch_to_json(
  preset_name : String,
  limit_preset : String,
  patch : Bytes,
  limits : @moonbsdiff.Limits,
) -> String {
  let patch_hex_val = if patch.length() <= 32768 {
    j_str(encode_hex_bytes(patch))
  } else {
    j_null()
  }
  let applied_json = limits_to_json(limits)
  match @moonbsdiff.analyze_patch(patch, limits) {
    Err(err) =>
      j_obj({
        "ok": j_bool(false),
        "preset_name": j_str(preset_name),
        "limit_preset": j_str(limit_preset),
        "patch_bytes_len": j_i64(patch.length().to_int64()),
        "patch_hex": patch_hex_val,
        "applied_limits": applied_json,
        "error": bsdiff_error_json(err),
      }).stringify()
    Ok(analysis) => {
      let hdr = analysis.deep.header
      let flags_json : Array[@json.Json] = []
      for flag in analysis.risk_flags {
        flags_json.push(
          j_obj({
            "code": j_str(flag.code),
            "severity": j_str(risk_level_name(flag.severity)),
            "detail": j_str(flag.detail),
          }),
        )
      }
      let controls_json : Array[@json.Json] = []
      for ctrl in analysis.sample_controls {
        controls_json.push(
          j_obj({
            "index": j_i64(ctrl.index),
            "add_bytes": j_i64(ctrl.add_bytes),
            "extra_bytes": j_i64(ctrl.extra_bytes),
            "seek_offset": j_i64(ctrl.seek_offset),
            "seek_offset_str": j_str("\{ctrl.seek_offset}"),
          }),
        )
      }
      let (moonbit_snippet, cli_flags) = build_required_snippets(
        analysis.required_limits,
      )
      j_obj({
        "ok": j_bool(true),
        "preset_name": j_str(preset_name),
        "limit_preset": j_str(limit_preset),
        "patch_bytes_len": j_i64(patch.length().to_int64()),
        "patch_hex": patch_hex_val,
        "applied_limits": applied_json,
        "header": j_obj({
          "header_bytes": j_int(32),
          "patch_bytes": j_i64(hdr.patch_bytes),
          "new_bytes": j_i64(hdr.new_bytes),
          "control_start": j_i64(hdr.control_start),
          "control_length": j_i64(hdr.control_length),
          "diff_start": j_i64(hdr.diff_start),
          "diff_length": j_i64(hdr.diff_length),
          "extra_start": j_i64(hdr.extra_start),
          "extra_length": j_i64(hdr.extra_length),
        }),
        "streams": j_obj({
          "ctrl_compressed_bytes": j_i64(analysis.ctrl_compressed_bytes),
          "diff_compressed_bytes": j_i64(analysis.diff_compressed_bytes),
          "extra_compressed_bytes": j_i64(analysis.extra_compressed_bytes),
          "total_compressed_bytes": j_i64(analysis.total_compressed_bytes),
          "control_count": j_i64(analysis.deep.control_count),
          "diff_bytes": j_i64(analysis.deep.diff_bytes),
          "extra_bytes": j_i64(analysis.deep.extra_bytes),
          "expanded_bytes": j_i64(analysis.deep.expanded_bytes),
        }),
        "ratios": j_obj({
          "expansion_ratio_permille": j_i64(analysis.expansion_ratio_permille),
          "diff_share_permille": j_i64(analysis.diff_share_permille),
          "extra_share_permille": j_i64(analysis.extra_share_permille),
          "patch_to_output_permille": j_i64(analysis.patch_to_output_permille),
        }),
        "seeks": j_obj({
          "negative_seek_count": j_i64(analysis.negative_seek_count),
          "max_abs_seek": j_i64(analysis.max_abs_seek),
          "max_abs_seek_str": j_str("\{analysis.max_abs_seek}"),
        }),
        "risk_level": j_str(risk_level_name(analysis.risk_level)),
        "risk_flags": j_arr(flags_json),
        "sample_controls": j_arr(controls_json),
        "required_limits": limits_to_json(analysis.required_limits),
        "moonbit_snippet": j_str(moonbit_snippet),
        "cli_flags": j_str(cli_flags),
      }).stringify()
    }
  }
}

///|
fn analyze_patch_preset_impl(
  preset_name : String,
  limit_preset : String,
) -> String {
  if !js_is_string(preset_name) {
    return j_obj({
      "ok": j_bool(false),
      "preset_name": j_null(),
      "limit_preset": if js_is_string(limit_preset) {
        j_str(limit_preset)
      } else {
        j_null()
      },
      "error": j_obj({
        "kind": j_str("InvalidRequest"),
        "stage": j_str("Configuration"),
        "block": j_null(),
        "offset": j_null(),
        "field": j_str("preset_name"),
        "value": j_null(),
        "limit": j_null(),
        "raw": j_str("preset_name must be a string"),
      }),
    }).stringify()
  }
  if !js_is_string(limit_preset) {
    return j_obj({
      "ok": j_bool(false),
      "preset_name": j_str(preset_name),
      "limit_preset": j_null(),
      "error": j_obj({
        "kind": j_str("InvalidRequest"),
        "stage": j_str("Configuration"),
        "block": j_null(),
        "offset": j_null(),
        "field": j_str("limit_preset"),
        "value": j_null(),
        "limit": j_null(),
        "raw": j_str("limit_preset must be a string"),
      }),
    }).stringify()
  }
  let patch = match build_xray_preset_patch(preset_name) {
    Some(p) => p
    None =>
      return j_obj({
        "ok": j_bool(false),
        "preset_name": j_str(preset_name),
        "limit_preset": j_str(limit_preset),
        "error": j_obj({
          "kind": j_str("UnknownPreset"),
          "stage": j_str("Configuration"),
          "field": j_str("preset_name"),
          "raw": j_str("unknown patch preset: " + preset_name),
        }),
      }).stringify()
  }
  let limits = limits_for_preset(limit_preset)
  analyze_patch_to_json(preset_name, limit_preset, patch, limits)
}

///|
const XRAY_MAX_UPLOAD_BYTES : Int32 = 2097152

///|
fn parse_xray_limit_param(
  field : String,
  raw : Double,
) -> Result[Int64, @json.Json] {
  if !js_is_number(raw) || raw != raw || raw - raw != 0.0 {
    return Err(
      j_obj({
        "kind": j_str("InvalidConfiguration"),
        "stage": j_str("Configuration"),
        "block": j_null(),
        "offset": j_null(),
        "field": j_str(field),
        "value": j_null(),
        "limit": j_null(),
        "raw": j_str("limit parameter " + field + " must be a finite integer"),
      }),
    )
  }
  if raw < -9007199254740991.0 || raw > 9007199254740991.0 {
    return Err(
      j_obj({
        "kind": j_str("InvalidConfiguration"),
        "stage": j_str("Configuration"),
        "block": j_null(),
        "offset": j_null(),
        "field": j_str(field),
        "value": j_null(),
        "limit": j_null(),
        "raw": j_str(
          "limit parameter " + field + " is outside safe integer range",
        ),
      }),
    )
  }
  if raw.floor() != raw {
    return Err(
      j_obj({
        "kind": j_str("InvalidConfiguration"),
        "stage": j_str("Configuration"),
        "block": j_null(),
        "offset": j_null(),
        "field": j_str(field),
        "value": j_null(),
        "limit": j_null(),
        "raw": j_str(
          "limit parameter " + field + " must be an integer (got non-integer)",
        ),
      }),
    )
  }
  Ok(raw.to_int64())
}

///|
fn xray_config_error_json(err : @json.Json) -> String {
  j_obj({
    "ok": j_bool(false),
    "preset_name": j_str("custom_upload"),
    "limit_preset": j_str("custom"),
    "error": err,
  }).stringify()
}

///|
fn analyze_patch_hex_impl(
  patch_hex : String,
  max_patch : Double,
  max_output : Double,
  max_decomp : Double,
  max_controls : Double,
) -> String {
  if !js_is_string(patch_hex) {
    return xray_config_error_json(
      j_obj({
        "kind": j_str("InvalidRequest"),
        "stage": j_str("Configuration"),
        "block": j_null(),
        "offset": j_null(),
        "field": j_str("patch_hex"),
        "value": j_null(),
        "limit": j_null(),
        "raw": j_str("patch_hex must be a string"),
      }),
    )
  }
  let max_patch_i64 = match
    parse_xray_limit_param("max_patch_bytes", max_patch) {
    Ok(v) => v
    Err(err) => return xray_config_error_json(err)
  }
  let max_output_i64 = match
    parse_xray_limit_param("max_output_bytes", max_output) {
    Ok(v) => v
    Err(err) => return xray_config_error_json(err)
  }
  let max_decomp_i64 = match
    parse_xray_limit_param("max_decompressed_bytes", max_decomp) {
    Ok(v) => v
    Err(err) => return xray_config_error_json(err)
  }
  let max_controls_i64 = match
    parse_xray_limit_param("max_control_instructions", max_controls) {
    Ok(v) => v
    Err(err) => return xray_config_error_json(err)
  }
  let patch = match decode_hex_bytes_bounded(patch_hex, XRAY_MAX_UPLOAD_BYTES) {
    Ok(b) => b
    Err((err_kind, msg)) => {
      let kind = if err_kind == "LimitExceeded" {
        "ResourceLimitExceeded"
      } else {
        "InvalidHex"
      }
      let limit_val = if err_kind == "LimitExceeded" {
        j_i64(XRAY_MAX_UPLOAD_BYTES.to_int64())
      } else {
        j_null()
      }
      return j_obj({
        "ok": j_bool(false),
        "preset_name": j_str("custom_upload"),
        "limit_preset": j_str("custom"),
        "error": j_obj({
          "kind": j_str(kind),
          "stage": j_str("Configuration"),
          "block": j_null(),
          "offset": j_null(),
          "field": j_str("patch_hex"),
          "value": j_null(),
          "limit": limit_val,
          "raw": j_str(msg),
        }),
      }).stringify()
    }
  }
  let limits : @moonbsdiff.Limits = {
    ..@moonbsdiff.Limits::for_apply(),
    max_patch_bytes: max_patch_i64,
    max_new_bytes: max_output_i64,
    max_output_bytes: max_output_i64,
    max_decompressed_bytes: max_decomp_i64,
    max_control_instructions: max_controls_i64,
  }
  analyze_patch_to_json("custom_upload", "custom", patch, limits)
}
