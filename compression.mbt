///|
fn decompression_budget(
  limits : Limits,
) -> Result[@bounded.Budget, BsdiffError] {
  match limits.validate() {
    Err(e) => Err(e)
    Ok(_) =>
      Ok(@bounded.Budget::{
        remaining: limits.max_decompressed_bytes,
        emitted: 0L,
      })
  }
}

///|
// Standard generator encoding is fixed at bzip2 level 9.
#warnings("-unused_value")
fn compress_block(data : Bytes) -> Bytes {
  @bzip2.bzip2(data[:], level=9)
}

///|
priv struct PatchBudget {
  mut used : Int64
  limit : Int64
}

///|
fn append_compressed(
  out : Array[Byte],
  part : Bytes,
  quota : PatchBudget,
  work : MatchBudget,
) -> Result[Unit, BsdiffError] {
  // used <= limit <= Int max; a Writer emission is bounded independently.
  let value = quota.used + part.length().to_int64()
  if value > quota.limit {
    return Err(
      generation_error(
        ResourceLimitExceeded,
        Header,
        "max_patch_bytes",
        value,
        Some(quota.limit),
      ),
    )
  }
  match work.reserve(2L * part.length().to_int64()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  quota.used = value
  for byte in part {
    out.push(byte)
  }
  Ok(())
}

///|
// One 32768-byte feed can emit at most one level-9 block (RLE <= 5/4
// expansion). The fixed Writer retains <=900004 RLE bytes; finish emits
// at most one block. Each returned emission is <3 MB, independently of input
// size. See docs/generation-resources.md for the bit and workspace bounds.
// The quota is shared by all three streams; no whole-input output is built
// before checking its size. No copied encoder source or engine change.
fn compress_generation_block(
  data : Bytes,
  quota : PatchBudget,
  work : MatchBudget,
) -> Result[Bytes, BsdiffError] {
  let writer = @bzip2.Writer::new(level=9)
  let out : Array[Byte] = []
  let mut at = 0
  while at < data.length() {
    match work.reserve(1L) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    let count = if data.length() - at < 32768 {
      data.length() - at
    } else {
      32768
    }
    let part = writer.push(data[at:at + count])
    match append_compressed(out, part, quota, work) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    at = at + count
  }
  match work.reserve(1L) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match append_compressed(out, writer.finish(), quota, work) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  Ok(Bytes::from_array(out))
}

///|
fn decompress_block(
  data : Bytes,
  cap : Int64,
  budget : @bounded.Budget,
  stage : ErrorStage,
  start : Int64,
) -> Result[Bytes, BsdiffError] {
  let block = match stage {
    Control => "control"
    Diff => "diff"
    Extra => "extra"
    _ =>
      return Err(
        format_error(
          InvalidConfiguration,
          stage,
          None,
          None,
          Some("stage"),
          None,
          None,
        ),
      )
  }
  if cap < 0L || cap > 2147483647L || budget.remaining < 0L || start < 0L {
    return Err(
      format_error(
        InvalidConfiguration,
        stage,
        Some(block),
        None,
        Some("compression_parameters"),
        None,
        None,
      ),
    )
  }
  if start > 9223372036854775807L - data.length().to_int64() {
    return Err(
      format_error(
        IntegerOverflow,
        stage,
        Some(block),
        None,
        Some("compressed_offset"),
        Some(start),
        None,
      ),
    )
  }
  Ok(@bounded.decode(data[:], cap.to_int(), budget).output) catch {
    @bounded.Truncated(at~) =>
      Err(
        format_error(
          TruncatedData,
          stage,
          Some(block),
          Some(start + at.to_int64()),
          None,
          None,
          None,
        ),
      )
    @bounded.Header(at~, what~) =>
      Err(
        format_error(
          InvalidField,
          stage,
          Some(block),
          Some(start + at.to_int64()),
          Some(what),
          None,
          None,
        ),
      )
    @bounded.Code(at~) =>
      Err(
        format_error(
          DecompressionFailed,
          stage,
          Some(block),
          Some(start + at.to_int64()),
          Some("code"),
          None,
          None,
        ),
      )
    @bounded.Checksum(_) =>
      Err(
        format_error(
          DecompressionFailed,
          stage,
          Some(block),
          None,
          Some("crc"),
          None,
          None,
        ),
      )
    @bounded.Limit(field~, value~, limit~) =>
      Err(
        format_error(
          ResourceLimitExceeded,
          stage,
          Some(block),
          None,
          Some(field),
          Some(value),
          Some(limit),
        ),
      )
    @bounded.Parameter =>
      Err(
        format_error(
          InvalidConfiguration,
          stage,
          Some(block),
          None,
          Some("budget"),
          None,
          None,
        ),
      )
  }
}
