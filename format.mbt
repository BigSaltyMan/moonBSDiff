///|
// Consumed by the later patch application stage.
#warnings("-unused_field")
priv struct PatchRanges {
  control_start : Int32
  control_end : Int32
  diff_end : Int32
  extra_end : Int32
  new_size : Int64
}

///|
// Internal until the apply stage integrates the parser.
#warnings("-unused_value")
fn parse_header(
  data : Bytes,
  limits : Limits,
) -> Result[PatchRanges, BsdiffError] {
  match limits.validate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let total = data.length().to_int64()
  if total > limits.max_patch_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        None,
        Some("max_patch_bytes"),
        Some(total),
        Some(limits.max_patch_bytes),
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
  Ok({
    control_start: 32,
    control_end: control_end.to_int(),
    diff_end: diff_end.to_int(),
    extra_end: data.length(),
    new_size: output,
  })
}
