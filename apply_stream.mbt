///|
pub impl Eq for PatchInfo with fn equal(self, other) {
  self.patch_bytes == other.patch_bytes &&
  self.new_bytes == other.new_bytes &&
  self.control_start == other.control_start &&
  self.control_length == other.control_length &&
  self.diff_start == other.diff_start &&
  self.diff_length == other.diff_length &&
  self.extra_start == other.extra_start &&
  self.extra_length == other.extra_length
}

///|
pub extend PatchInfo with Eq::{equal, not_equal}

///|
pub impl @debug.Debug for PatchInfo with fn to_repr(self) {
  @debug.Repr::record({
    "patch_bytes": Repr(self.patch_bytes),
    "new_bytes": Repr(self.new_bytes),
    "control_start": Repr(self.control_start),
    "control_length": Repr(self.control_length),
    "diff_start": Repr(self.diff_start),
    "diff_length": Repr(self.diff_length),
    "extra_start": Repr(self.extra_start),
    "extra_length": Repr(self.extra_length),
  })
}

///|
pub extend PatchInfo with @debug.Debug::{to_repr}

///|
pub impl Eq for DeepPatchInfo with fn equal(self, other) {
  self.header == other.header &&
  self.control_count == other.control_count &&
  self.diff_bytes == other.diff_bytes &&
  self.extra_bytes == other.extra_bytes &&
  self.expanded_bytes == other.expanded_bytes
}

///|
pub extend DeepPatchInfo with Eq::{equal, not_equal}

///|
pub impl @debug.Debug for DeepPatchInfo with fn to_repr(self) {
  @debug.Repr::record({
    "header": Repr(self.header),
    "control_count": Repr(self.control_count),
    "diff_bytes": Repr(self.diff_bytes),
    "extra_bytes": Repr(self.extra_bytes),
    "expanded_bytes": Repr(self.expanded_bytes),
  })
}

///|
pub extend DeepPatchInfo with @debug.Debug::{to_repr}

///|
/// Phase notification emitted by `apply_stream`.
#derive(Eq, Debug)
pub(all) enum StreamApplyStage {
  HeaderVerified(PatchInfo)
  Restoring
  Validating
}

///|
pub extend StreamApplyStage with Eq::{equal, not_equal}

///|
pub extend StreamApplyStage with @debug.Debug::{to_repr}

///|
/// Failure returned by `apply_stream`: either a strict BSDIFF40/limit error
/// or an error/cancellation returned by one of the caller's callbacks.
#derive(Eq, Debug)
pub(all) enum StreamApplyError[E] {
  Bsdiff(BsdiffError)
  Io(E)
}

///|
pub extend StreamApplyError with Eq::{equal, not_equal}

///|
pub extend StreamApplyError with @debug.Debug::{to_repr}

///|
priv struct PatchStreamState[E] {
  mut io_err : E?
  mut bsdiff_err : BsdiffError?
}

///|
priv struct PatchStream[E] {
  reader : @bounded.StreamReader
  stage : ErrorStage
  start : Int64
  state : PatchStreamState[E]
}

///|
fn[E] emit_stage(
  on_stage : ((StreamApplyStage) -> Result[Unit, E])?,
  stage : StreamApplyStage,
) -> Result[Unit, StreamApplyError[E]] {
  match on_stage {
    Some(cb) =>
      match cb(stage) {
        Ok(_) => Ok(())
        Err(e) => Err(Io(e))
      }
    None => Ok(())
  }
}

///|
fn[E] run_checkpoint(
  checkpoint : (() -> Result[Unit, E])?,
) -> Result[Unit, StreamApplyError[E]] {
  match checkpoint {
    Some(cb) =>
      match cb() {
        Ok(_) => Ok(())
        Err(e) => Err(Io(e))
      }
    None => Ok(())
  }
}

///|
fn[E] emit_output(
  write_output : (Bytes) -> Result[Unit, E],
  chunk : Bytes,
) -> Result[Unit, StreamApplyError[E]] {
  match write_output(chunk) {
    Ok(_) => Ok(())
    Err(e) => Err(Io(e))
  }
}

///|
fn[E] read_exact_range(
  read_at : (Int64, Int32) -> Result[Bytes, E],
  base_offset : Int64,
  count : Int32,
  stage : ErrorStage,
  block : String?,
  eof_field : String?,
  length_field : String,
) -> Result[Bytes, StreamApplyError[E]] {
  let buf : Array[Byte] = []
  while buf.length() < count {
    let rem = count - buf.length()
    let at = base_offset + buf.length().to_int64()
    let chunk = match read_at(at, rem) {
      Ok(bytes) => bytes
      Err(e) => return Err(Io(e))
    }
    if chunk.length() == 0 {
      return Err(
        Bsdiff(
          format_error(
            TruncatedData,
            stage,
            block,
            Some(at),
            eof_field,
            if eof_field is Some(_) {
              Some(buf.length().to_int64())
            } else {
              None
            },
            Some(count.to_int64()),
          ),
        ),
      )
    }
    if chunk.length() > rem {
      return Err(
        Bsdiff(
          format_error(
            InvalidField,
            stage,
            block,
            Some(at),
            Some(length_field),
            Some(chunk.length().to_int64()),
            Some(rem.to_int64()),
          ),
        ),
      )
    }
    for byte in chunk {
      buf.push(byte)
    }
  }
  Ok(Bytes::from_array(buf))
}

///|
fn[E] PatchStreamState::resolve_fault(
  self : PatchStreamState[E],
  fault : @bounded.Fault,
  stage : ErrorStage,
  start : Int64,
) -> StreamApplyError[E] {
  match self.io_err {
    Some(e) => Io(e)
    None =>
      match self.bsdiff_err {
        Some(err) => Bsdiff(err)
        None => Bsdiff(compression_fault(fault, stage, start))
      }
  }
}

///|
fn[E] PatchStream::open(
  start : Int64,
  length : Int64,
  cap : Int32,
  budget : @bounded.Budget,
  stage : ErrorStage,
  block : String,
  read_patch_at : (Int64, Int32) -> Result[Bytes, E],
) -> Result[PatchStream[E], StreamApplyError[E]] {
  let state : PatchStreamState[E] = { io_err: None, bsdiff_err: None, }
  let mut at = 0L
  let source = fn() {
    if state.io_err is Some(_) || state.bsdiff_err is Some(_) {
      return b""
    }
    let remaining = length - at
    if remaining <= 0L {
      return b""
    }
    let want = Int64::min(4096L, remaining).to_int()
    match read_patch_at(start + at, want) {
      Err(e) => {
        state.io_err = Some(e)
        b""
      }
      Ok(chunk) =>
        if chunk.length() == 0 {
          state.bsdiff_err = Some(
            format_error(
              TruncatedData,
              stage,
              Some(block),
              Some(start + at),
              None,
              None,
              Some(start + length),
            ),
          )
          b""
        } else if chunk.length() > want {
          state.bsdiff_err = Some(
            format_error(
              InvalidField,
              stage,
              Some(block),
              Some(start + at),
              Some("patch_read_length"),
              Some(chunk.length().to_int64()),
              Some(want.to_int64()),
            ),
          )
          b""
        } else {
          at += chunk.length().to_int64()
          chunk
        }
    }
  }
  let reader = @bounded.StreamReader::new(length.to_int(), source, cap, budget) catch {
    fault => return Err(state.resolve_fault(fault, stage, start))
  }
  Ok({ reader, stage, start, state, })
}

///|
fn[E] PatchStream::read_chunk(
  self : PatchStream[E],
  count : Int32,
) -> Result[Bytes, StreamApplyError[E]] {
  let chunk = self.reader.read(count) catch {
    fault => return Err(self.state.resolve_fault(fault, self.stage, self.start))
  }
  match self.state.io_err {
    Some(e) => return Err(Io(e))
    None => ()
  }
  match self.state.bsdiff_err {
    Some(err) => return Err(Bsdiff(err))
    None => ()
  }
  Ok(chunk)
}

///|
fn[E] PatchStream::read_exact(
  self : PatchStream[E],
  count : Int32,
  field : String,
) -> Result[Bytes, StreamApplyError[E]] {
  let out : Array[Byte] = []
  while out.length() < count {
    let chunk = match self.read_chunk(count - out.length()) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    if chunk.length() == 0 {
      return Err(
        Bsdiff(
          apply_error(
            TruncatedData,
            self.stage,
            field,
            Some(out.length().to_int64()),
            Some(count.to_int64()),
          ),
        ),
      )
    }
    for byte in chunk {
      out.push(byte)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
fn[E] PatchStream::read_exact_payload(
  self : PatchStream[E],
  count : Int32,
  field : String,
  total_expected : Int64,
  consumed_before : Int64,
) -> Result[Bytes, StreamApplyError[E]] {
  let out : Array[Byte] = []
  while out.length() < count {
    let chunk = match self.read_chunk(count - out.length()) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    if chunk.length() == 0 {
      return Err(
        Bsdiff(
          apply_error(
            TruncatedData,
            self.stage,
            field,
            Some(total_expected),
            Some(consumed_before + out.length().to_int64()),
          ),
        ),
      )
    }
    for byte in chunk {
      out.push(byte)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
fn validate_stream_bounds(
  old_size : Int64,
  patch_size : Int64,
  limits : Limits,
) -> Result[Unit, BsdiffError] {
  match limits.validate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  if old_size < 0L {
    return Err(
      format_error(
        InvalidField,
        Header,
        None,
        None,
        Some("old_size"),
        Some(old_size),
        None,
      ),
    )
  }
  if old_size > limits.max_old_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        None,
        Some("max_old_bytes"),
        Some(old_size),
        Some(limits.max_old_bytes),
      ),
    )
  }
  if patch_size < 0L {
    return Err(
      format_error(
        InvalidField,
        Header,
        None,
        None,
        Some("patch_bytes"),
        Some(patch_size),
        Some(2147483647L),
      ),
    )
  }
  if patch_size > limits.max_patch_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        None,
        Some("max_patch_bytes"),
        Some(patch_size),
        Some(limits.max_patch_bytes),
      ),
    )
  }
  Ok(())
}

///|
fn[E] verify_patch_header(
  patch_size : Int64,
  limits : Limits,
  read_patch_at : (Int64, Int32) -> Result[Bytes, E],
) -> Result[PatchInfo, StreamApplyError[E]] {
  let header_want = Int64::min(32L, patch_size).to_int()
  let header = match
    read_exact_range(
      read_patch_at,
      0L,
      header_want,
      Header,
      None,
      None,
      "patch_read_length",
    ) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let info = match
    inspect_header_prefix(header, patch_size, limits.max_patch_bytes) {
    Ok(v) => v
    Err(e) => return Err(Bsdiff(e))
  }
  if info.new_bytes > limits.max_output_bytes {
    return Err(
      Bsdiff(
        format_error(
          ResourceLimitExceeded,
          Header,
          None,
          Some(24L),
          Some("max_output_bytes"),
          Some(info.new_bytes),
          Some(limits.max_output_bytes),
        ),
      ),
    )
  }
  if info.new_bytes > limits.max_new_bytes {
    return Err(
      Bsdiff(
        format_error(
          ResourceLimitExceeded,
          Header,
          None,
          Some(24L),
          Some("max_new_bytes"),
          Some(info.new_bytes),
          Some(limits.max_new_bytes),
        ),
      ),
    )
  }
  Ok(info)
}

///|
fn[E] apply_diff_chunk(
  delta : PatchStream[E],
  old_size : Int64,
  oldpos : Int64,
  done : Int64,
  count : Int32,
  total_expected : Int64,
  consumed_before : Int64,
  read_old_at : (Int64, Int32) -> Result[Bytes, E],
  write_output : (Bytes) -> Result[Unit, E],
) -> Result[Unit, StreamApplyError[E]] {
  let delta_chunk = match
    delta.read_exact_payload(
      count, "diff_decoded_consumption", total_expected, consumed_before,
    ) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let pos = match cursor_add(oldpos, done, "old_plus_x") {
    Ok(v) => v
    Err(e) => return Err(Bsdiff(e))
  }
  // Never negate Int64.min. Only a negative position within this chunk can
  // overlap zero; it is then proven to fit an Int before negating.
  let prefix = if pos >= 0L {
    0
  } else if pos < -count.to_int64() {
    count
  } else {
    (-pos).to_int()
  }
  let oldat = if pos < 0L { 0L } else { pos }
  let available = if oldat >= old_size {
    0
  } else {
    Int64::min((count - prefix).to_int64(), old_size - oldat).to_int()
  }
  let out_chunk = if available == 0 {
    delta_chunk
  } else {
    let old_chunk = match
      read_exact_range(
        read_old_at,
        oldat,
        available,
        Diff,
        Some("old"),
        Some("old_read_eof"),
        "old_read_length",
      ) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    Bytes::from_array(
      Array::makei(count, i => {
        if i >= prefix && i - prefix < available {
          ((delta_chunk[i].to_int() + old_chunk[i - prefix].to_int()) & 0xff).to_byte()
        } else {
          delta_chunk[i]
        }
      }),
    )
  }
  emit_output(write_output, out_chunk)
}

///|
/// Apply a strict BSDIFF40 patch in bounded <=4096-byte chunks using explicit
/// resource limits. Cross-target (native, js, wasm-gc); never buffers whole
/// old, patch, or output files in memory.
pub fn[E] apply_stream(
  old_size : Int64,
  patch_size : Int64,
  limits : Limits,
  read_old_at~ : (Int64, Int32) -> Result[Bytes, E],
  read_patch_at~ : (Int64, Int32) -> Result[Bytes, E],
  write_output~ : (Bytes) -> Result[Unit, E],
  on_stage? : (StreamApplyStage) -> Result[Unit, E],
  checkpoint? : () -> Result[Unit, E],
) -> Result[DeepPatchInfo, StreamApplyError[E]] {
  match validate_stream_bounds(old_size, patch_size, limits) {
    Err(e) => return Err(Bsdiff(e))
    Ok(_) => ()
  }
  let info = match verify_patch_header(patch_size, limits, read_patch_at) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match emit_stage(on_stage, HeaderVerified(info)) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match emit_stage(on_stage, Restoring) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let budget = @bounded.Budget::{
    remaining: limits.max_decompressed_bytes,
    emitted: 0L,
  }
  let control_cap = if limits.max_control_instructions > 2147483647L / 24L {
    2147483647
  } else {
    (limits.max_control_instructions * 24L).to_int()
  }
  let output_cap = info.new_bytes.to_int()
  let control = match
    PatchStream::open(
      info.control_start,
      info.control_length,
      control_cap,
      budget,
      Control,
      "control",
      read_patch_at,
    ) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let delta = match
    PatchStream::open(
      info.diff_start,
      info.diff_length,
      output_cap,
      budget,
      Diff,
      "diff",
      read_patch_at,
    ) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let extra = match
    PatchStream::open(
      info.extra_start,
      info.extra_length,
      output_cap,
      budget,
      Extra,
      "extra",
      read_patch_at,
    ) {
    Ok(s) => s
    Err(e) => return Err(e)
  }
  let mut produced = 0L
  let mut oldpos = 0L
  let mut control_count = 0L
  let mut diff_bytes = 0L
  let mut extra_bytes = 0L
  while produced < info.new_bytes {
    match run_checkpoint(checkpoint) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if control_count >= limits.max_control_instructions {
      return Err(
        Bsdiff(
          apply_error(
            ResourceLimitExceeded,
            Control,
            "max_control_instructions",
            Some(control_count + 1L),
            Some(limits.max_control_instructions),
          ),
        ),
      )
    }
    let triple = match control.read_exact(24, "control_triple_bytes") {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    let x = match decode_int(triple, 0, Control) {
      Ok(v) => v
      Err(e) => return Err(Bsdiff(e))
    }
    let y = match decode_int(triple, 8, Control) {
      Ok(v) => v
      Err(e) => return Err(Bsdiff(e))
    }
    let z = match decode_int(triple, 16, Control) {
      Ok(v) => v
      Err(e) => return Err(Bsdiff(e))
    }
    if x < 0L {
      return Err(
        Bsdiff(apply_error(InvalidField, Control, "diff_length", Some(x), None)),
      )
    }
    if y < 0L {
      return Err(
        Bsdiff(
          apply_error(InvalidField, Control, "extra_length", Some(y), None),
        ),
      )
    }
    let remaining = info.new_bytes - produced
    if x > remaining {
      return Err(
        Bsdiff(
          apply_error(
            OutputOutOfBounds,
            Control,
            "diff_length",
            Some(x),
            Some(remaining),
          ),
        ),
      )
    }
    if y > remaining - x {
      return Err(
        Bsdiff(
          apply_error(
            OutputOutOfBounds,
            Control,
            "extra_length",
            Some(y),
            Some(remaining - x),
          ),
        ),
      )
    }
    let oldend = match cursor_add(oldpos, x, "old_plus_x") {
      Ok(v) => v
      Err(e) => return Err(Bsdiff(e))
    }
    let next_old = match cursor_add(oldend, z, "old_plus_z") {
      Ok(v) => v
      Err(e) => return Err(Bsdiff(e))
    }
    let mut done = 0L
    while done < x {
      match run_checkpoint(checkpoint) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      let count = Int64::min(4096L, x - done).to_int()
      match
        apply_diff_chunk(
          delta,
          old_size,
          oldpos,
          done,
          count,
          diff_bytes + x,
          diff_bytes + done,
          read_old_at,
          write_output,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      done += count.to_int64()
    }
    let mut extra_done = 0L
    while extra_done < y {
      match run_checkpoint(checkpoint) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      let count = Int64::min(4096L, y - extra_done).to_int()
      let extra_chunk = match
        extra.read_exact_payload(
          count,
          "extra_decoded_consumption",
          extra_bytes + y,
          extra_bytes + extra_done,
        ) {
        Ok(b) => b
        Err(e) => return Err(e)
      }
      match emit_output(write_output, extra_chunk) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      extra_done += count.to_int64()
    }
    produced += x + y
    diff_bytes += x
    extra_bytes += y
    control_count += 1L
    oldpos = next_old
  }
  match emit_stage(on_stage, Validating) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  for
    entry in [
      (control, "unconsumed_control"),
      (delta, "unconsumed_diff"),
      (extra, "unconsumed_extra"),
    ] {
    match run_checkpoint(checkpoint) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    let (stream, field) = entry
    let tail = match stream.read_chunk(1) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    if tail.length() != 0 {
      return Err(
        Bsdiff(apply_error(InvalidField, stream.stage, field, None, None)),
      )
    }
  }
  Ok({
    header: info,
    control_count,
    diff_bytes,
    extra_bytes,
    expanded_bytes: budget.emitted,
  })
}
