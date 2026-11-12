///|
priv struct PatchRanges {
  control_start : Int32
  control_end : Int32
  diff_end : Int32
  extra_end : Int32
  new_size : Int64
}

///|
fn parse_header(
  data : Bytes,
  limits : Limits,
) -> Result[PatchRanges, BsdiffError] {
  match limits.validate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let ranges = match parse_envelope(data, limits.max_patch_bytes) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  let output = ranges.new_size
  if output > limits.max_output_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        Some(24L),
        Some("max_output_bytes"),
        Some(output),
        Some(limits.max_output_bytes),
      ),
    )
  }
  Ok(ranges)
}

///|
// Shared structural checks. No decoding and no restored-buffer size policy.
fn parse_envelope(
  data : Bytes,
  max_patch_bytes : Int64,
) -> Result[PatchRanges, BsdiffError] {
  let total = data.length().to_int64()
  if total > max_patch_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        None,
        Some("max_patch_bytes"),
        Some(total),
        Some(max_patch_bytes),
      ),
    )
  }
  if data.length() < 32 {
    return Err(
      format_error(
        TruncatedData,
        Header,
        None,
        Some(total),
        None,
        None,
        Some(32L),
      ),
    )
  }
  let magic = b"BSDIFF40"
  for i in 0..<8 {
    if data[i] != magic[i] {
      return Err(
        format_error(
          UnsupportedFormat,
          Header,
          None,
          Some(i.to_int64()),
          Some("magic"),
          None,
          None,
        ),
      )
    }
  }
  let control = match decode_int(data, 8, Header) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let diff = match decode_int(data, 16, Header) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  let output = match decode_int(data, 24, Header) {
    Ok(x) => x
    Err(e) => return Err(e)
  }
  for
    (name, value, offset) in [
      ("control_length", control, 8L),
      ("diff_length", diff, 16L),
      ("new_size", output, 24L),
    ] {
    if value < 0L {
      return Err(
        format_error(
          InvalidField,
          Header,
          None,
          Some(offset),
          Some(name),
          Some(value),
          None,
        ),
      )
    }
  }
  let max = 9223372036854775807L
  if control > max - 32L {
    return Err(
      format_error(
        IntegerOverflow,
        Header,
        Some("control"),
        Some(8L),
        Some("control_length"),
        Some(control),
        None,
      ),
    )
  }
  let control_end = 32L + control
  if diff > max - control_end {
    return Err(
      format_error(
        IntegerOverflow,
        Header,
        Some("diff"),
        Some(16L),
        Some("diff_length"),
        Some(diff),
        None,
      ),
    )
  }
  let diff_end = control_end + diff
  if control_end > total {
    return Err(
      format_error(
        TruncatedData,
        Header,
        Some("control"),
        Some(8L),
        Some("control_length"),
        Some(control),
        Some(total),
      ),
    )
  }
  if diff_end > total {
    return Err(
      format_error(
        TruncatedData,
        Header,
        Some("diff"),
        Some(16L),
        Some("diff_length"),
        Some(diff),
        Some(total),
      ),
    )
  }
  Ok({
    control_start: 32,
    control_end: control_end.to_int(),
    diff_end: diff_end.to_int(),
    extra_end: data.length(),
    new_size: output,
  })
}

///|
/// Read-only envelope metadata; it makes no claim about compressed/control data.
pub struct PatchInfo {
  patch_bytes : Int64
  new_bytes : Int64
  control_start : Int64
  control_length : Int64
  diff_start : Int64
  diff_length : Int64
  extra_start : Int64
  extra_length : Int64
}

///|
/// Check BSDIFF40 header/ranges only. The positive Int-indexable patch cap is
/// independent of apply defaults. Never decompresses or allocates restored bytes.
pub fn inspect_header(
  data : Bytes,
  max_patch_bytes : Int64,
) -> Result[PatchInfo, BsdiffError] {
  if max_patch_bytes <= 0L || max_patch_bytes > 2147483647L {
    return Err(
      format_error(
        InvalidConfiguration,
        Configuration,
        None,
        None,
        Some("max_patch_bytes"),
        Some(max_patch_bytes),
        Some(2147483647L),
      ),
    )
  }
  let ranges = match parse_envelope(data, max_patch_bytes) {
    Ok(value) => value
    Err(e) => return Err(e)
  }
  Ok({
    patch_bytes: data.length().to_int64(),
    new_bytes: ranges.new_size,
    control_start: ranges.control_start.to_int64(),
    control_length: (ranges.control_end - ranges.control_start).to_int64(),
    diff_start: ranges.control_end.to_int64(),
    diff_length: (ranges.diff_end - ranges.control_end).to_int64(),
    extra_start: ranges.diff_end.to_int64(),
    extra_length: (ranges.extra_end - ranges.diff_end).to_int64(),
  })
}
