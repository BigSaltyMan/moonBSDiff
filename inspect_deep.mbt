///|
/// Verified structure and decoded byte counts for a single BSDIFF40 patch.
pub struct DeepPatchInfo {
  header : PatchInfo
  control_count : Int64
  diff_bytes : Int64
  extra_bytes : Int64
  expanded_bytes : Int64
}

///|
/// Check all three compressed streams and their control-directed consumption.
/// Uses explicit limits and bounded decoder pulls, with no old or restored data.
/// Success establishes patch structure; content and file identity need separate checks.
pub fn inspect_deep(
  patch : Bytes,
  limits : Limits,
) -> Result[DeepPatchInfo, BsdiffError] {
  let ranges = match parse_header(patch, limits) {
    Err(error) => return Err(error)
    Ok(value) => value
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
  Ok(inspect_streams(patch, ranges, limits)) catch {
    InspectionFailed(error) => Err(error)
  }
}

///|
priv suberror InspectFault {
  InspectionFailed(BsdiffError)
}

///|
fn[T] inspect_or_raise(result : Result[T, BsdiffError]) -> T raise InspectFault {
  match result {
    Ok(value) => value
    Err(error) => raise InspectionFailed(error)
  }
}

///|
priv struct InspectStream {
  reader : @bounded.StreamReader
  stage : ErrorStage
  start : Int64
}

///|
fn InspectStream::open(
  patch : Bytes,
  start : Int32,
  end : Int32,
  cap : Int32,
  budget : @bounded.Budget,
  stage : ErrorStage,
) -> InspectStream raise InspectFault {
  // The envelope already bounded both ends against this exact buffer.
  let mut at = start
  let reader = @bounded.StreamReader::new(
    end - start,
    fn() {
      let next = at + Int32::min(4096, end - at)
      let chunk = patch[at:next].to_owned()
      at = next
      chunk
    },
    cap,
    budget,
  ) catch {
    fault =>
      raise InspectionFailed(compression_fault(fault, stage, start.to_int64()))
  }
  { reader, stage, start: start.to_int64(), }
}

///|
fn InspectStream::read(
  self : InspectStream,
  count : Int32,
) -> Bytes raise InspectFault {
  self.reader.read(count) catch {
    fault =>
      raise InspectionFailed(compression_fault(fault, self.stage, self.start))
  }
}

///|
fn InspectStream::consume(
  self : InspectStream,
  size : Int64,
) -> Unit raise InspectFault {
  let mut remaining = size
  while remaining > 0L {
    let count = Int64::min(4096L, remaining).to_int()
    let actual = self.read(count).length()
    remaining -= actual.to_int64()
    if actual < count {
      raise InspectionFailed(
        apply_error(
          TruncatedData,
          self.stage,
          "decoded_consumption",
          Some(size),
          Some(size - remaining),
        ),
      )
    }
  }
}

///|
fn inspect_output_length(
  length : Int64,
  remaining : Int64,
  field : String,
) -> Unit raise InspectFault {
  if length > remaining {
    raise InspectionFailed(
      apply_error(
        OutputOutOfBounds,
        Control,
        field,
        Some(length),
        Some(remaining),
      ),
    )
  }
}

///|
fn inspect_streams(
  patch : Bytes,
  ranges : PatchRanges,
  limits : Limits,
) -> DeepPatchInfo raise InspectFault {
  let budget = @bounded.Budget::{
    remaining: limits.max_decompressed_bytes,
    emitted: 0L,
  }
  let control_cap = if limits.max_control_instructions > 2147483647L / 24L {
    2147483647
  } else {
    (limits.max_control_instructions * 24L).to_int()
  }
  let output_cap = ranges.new_size.to_int()
  let control = InspectStream::open(
    patch,
    ranges.control_start,
    ranges.control_end,
    control_cap,
    budget,
    Control,
  )
  let delta = InspectStream::open(
    patch,
    ranges.control_end,
    ranges.diff_end,
    output_cap,
    budget,
    Diff,
  )
  let extra = InspectStream::open(
    patch,
    ranges.diff_end,
    ranges.extra_end,
    output_cap,
    budget,
    Extra,
  )
  let mut control_count = 0L
  let mut diff_bytes = 0L
  let mut extra_bytes = 0L
  let mut oldpos = 0L
  let mut remaining = ranges.new_size
  while remaining > 0L {
    if control_count >= limits.max_control_instructions {
      raise InspectionFailed(
        apply_error(
          ResourceLimitExceeded,
          Control,
          "max_control_instructions",
          Some(control_count + 1L),
          Some(limits.max_control_instructions),
        ),
      )
    }
    let triple = control.read(24)
    if triple.length() != 24 {
      raise InspectionFailed(
        apply_error(
          TruncatedData,
          Control,
          "control_triple_bytes",
          Some(triple.length().to_int64()),
          Some(24L),
        ),
      )
    }
    let x = inspect_or_raise(decode_int(triple, 0, Control))
    let y = inspect_or_raise(decode_int(triple, 8, Control))
    let z = inspect_or_raise(decode_int(triple, 16, Control))
    for (field, value) in [("x", x), ("y", y)] {
      if value < 0L {
        raise InspectionFailed(
          apply_error(InvalidField, Control, field, Some(value), None),
        )
      }
    }
    control_count += 1L
    inspect_output_length(x, remaining, "x")
    let oldend = inspect_or_raise(cursor_add(oldpos, x, "old_plus_x"))
    delta.consume(x)
    diff_bytes += x
    remaining -= x
    inspect_output_length(y, remaining, "y")
    extra.consume(y)
    extra_bytes += y
    remaining -= y
    oldpos = inspect_or_raise(cursor_add(oldend, z, "old_plus_z"))
  }
  // A pull to verified EOF checks the final CRCs and the compressed boundary.
  for stream in [control, delta, extra] {
    if stream.read(1).length() != 0 {
      raise InspectionFailed(
        apply_error(
          InvalidField,
          stream.stage,
          "unconsumed_decoded_data",
          None,
          None,
        ),
      )
    }
  }
  // Verified EOF proves every byte reserved by the decoders was consumed.
  {
    header: ranges.info(),
    control_count,
    diff_bytes,
    extra_bytes,
    expanded_bytes: budget.emitted,
  }
}
