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
fn compress_block(data : Bytes) -> Bytes {
  @bzip2.bzip2(data[:], level=9)
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
