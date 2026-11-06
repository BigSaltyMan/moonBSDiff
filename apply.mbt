///|
fn apply_error(
  kind : ErrorKind,
  stage : ErrorStage,
  field : String,
  value : Int64?,
  limit : Int64?,
) -> BsdiffError {
  format_error(
    kind,
    stage,
    Some(
      match stage {
        Control => "control"
        Diff => "diff"
        Extra => "extra"
        _ => "output"
      },
    ),
    None,
    Some(field),
    value,
    limit,
  )
}

///|
fn cursor_add(
  a : Int64,
  b : Int64,
  field : String,
) -> Result[Int64, BsdiffError] {
  if (b > 0L && a > 9223372036854775807L - b) ||
    (b < 0L && a < -9223372036854775807L - 1L - b) {
    Err(apply_error(IntegerOverflow, Control, field, Some(a), None))
  } else {
    Ok(a + b)
  }
}

///|
/// Apply one strict BSDIFF40 patch using explicit resource limits.
/// The caller is responsible for verifying old/output file identities.
pub fn apply(
  old_bytes : Bytes,
  patch_bytes : Bytes,
  limits : Limits,
) -> Result[Bytes, BsdiffError] {
  match limits.validate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if old_bytes.length().to_int64() > limits.max_old_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        None,
        Some("max_old_bytes"),
        Some(old_bytes.length().to_int64()),
        Some(limits.max_old_bytes),
      ),
    )
  }
  let ranges = match parse_header(patch_bytes, limits) {
    Err(e) => return Err(e)
    Ok(r) => r
  }
  if ranges.new_size > limits.max_new_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        Some(24L),
        Some("max_new_bytes"),
        Some(ranges.new_size),
        Some(limits.max_new_bytes),
      ),
    )
  }
  let budget = match decompression_budget(limits) {
    Err(e) => return Err(e)
    Ok(b) => b
  }
  let control_cap = if limits.max_control_instructions > 2147483647L / 24L {
    2147483647L
  } else {
    limits.max_control_instructions * 24L
  }
  let control = match
    decompress_block(
      patch_bytes[ranges.control_start:ranges.control_end].to_owned(),
      control_cap,
      budget,
      Control,
      ranges.control_start.to_int64(),
    ) {
    Err(e) => return Err(e)
    Ok(b) => b
  }
  let diff = match
    decompress_block(
      patch_bytes[ranges.control_end:ranges.diff_end].to_owned(),
      ranges.new_size,
      budget,
      Diff,
      ranges.control_end.to_int64(),
    ) {
    Err(e) => return Err(e)
    Ok(b) => b
  }
  let extra = match
    decompress_block(
      patch_bytes[ranges.diff_end:ranges.extra_end].to_owned(),
      ranges.new_size,
      budget,
      Extra,
      ranges.diff_end.to_int64(),
    ) {
    Err(e) => return Err(e)
    Ok(b) => b
  }
  if control.length() % 24 != 0 {
    return Err(
      apply_error(
        TruncatedData,
        Control,
        "control_decoded_alignment",
        Some(control.length().to_int64()),
        Some(24L),
      ),
    )
  }
  if (control.length() / 24).to_int64() > limits.max_control_instructions {
    return Err(
      apply_error(
        ResourceLimitExceeded,
        Control,
        "max_control_instructions",
        Some((control.length() / 24).to_int64()),
        Some(limits.max_control_instructions),
      ),
    )
  }
  let size = ranges.new_size.to_int()
  let output = Array::make(size, b'\x00')
  let mut produced = 0
  let mut old_pos = 0L
  let mut diff_pos = 0
  let mut extra_pos = 0
  for pos = 0; pos < control.length(); pos = pos + 24 {
    if produced == size {
      return Err(
        apply_error(
          InvalidField,
          Control,
          "unconsumed_control",
          Some(pos.to_int64()),
          None,
        ),
      )
    }
    let x = match decode_int(control, pos, Control) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    let y = match decode_int(control, pos + 8, Control) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    let z = match decode_int(control, pos + 16, Control) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    let field = "control_decoded_byte[\{pos}]"
    if x < 0L {
      return Err(
        apply_error(InvalidField, Control, field + ".x", Some(x), None),
      )
    }
    if y < 0L {
      return Err(
        apply_error(InvalidField, Control, field + ".y", Some(y), None),
      )
    }
    if x > (size - produced).to_int64() {
      return Err(
        apply_error(
          OutputOutOfBounds,
          Control,
          field + ".x",
          Some(x),
          Some((size - produced).to_int64()),
        ),
      )
    }
    if y > (size - produced).to_int64() - x {
      return Err(
        apply_error(
          OutputOutOfBounds,
          Control,
          field + ".y",
          Some(y),
          Some((size - produced).to_int64() - x),
        ),
      )
    }
    if x > (diff.length() - diff_pos).to_int64() {
      return Err(
        apply_error(
          TruncatedData,
          Diff,
          "diff_decoded_consumption",
          Some(x),
          Some((diff.length() - diff_pos).to_int64()),
        ),
      )
    }
    if y > (extra.length() - extra_pos).to_int64() {
      return Err(
        apply_error(
          TruncatedData,
          Extra,
          "extra_decoded_consumption",
          Some(y),
          Some((extra.length() - extra_pos).to_int64()),
        ),
      )
    }
    let after_x = match cursor_add(old_pos, x, field + ".old_plus_x") {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    let next_old = match cursor_add(after_x, z, field + ".old_plus_z") {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    for i in 0..<x.to_int() {
      let at = old_pos + i.to_int64()
      let contribution = if at >= 0L && at < old_bytes.length().to_int64() {
        old_bytes[at.to_int()].to_int()
      } else {
        0
      }
      output[produced + i] = ((diff[diff_pos + i].to_int() + contribution) % 256).to_byte()
    }
    produced = produced + x.to_int()
    diff_pos = diff_pos + x.to_int()
    for i in 0..<y.to_int() {
      output[produced + i] = extra[extra_pos + i]
    }
    produced = produced + y.to_int()
    extra_pos = extra_pos + y.to_int()
    old_pos = next_old
  }
  if produced != size {
    return Err(
      apply_error(
        TruncatedData,
        Output,
        "output_size",
        Some(produced.to_int64()),
        Some(ranges.new_size),
      ),
    )
  }
  if diff_pos != diff.length() {
    return Err(
      apply_error(
        InvalidField,
        Diff,
        "unconsumed_diff",
        Some(diff_pos.to_int64()),
        Some(diff.length().to_int64()),
      ),
    )
  }
  if extra_pos != extra.length() {
    return Err(
      apply_error(
        InvalidField,
        Extra,
        "unconsumed_extra",
        Some(extra_pos.to_int64()),
        Some(extra.length().to_int64()),
      ),
    )
  }
  Ok(Bytes::from_array(output))
}
