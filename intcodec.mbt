///|
fn format_error(
  kind : ErrorKind,
  stage : ErrorStage,
  block : String?,
  offset : Int64?,
  field : String?,
  value : Int64?,
  limit : Int64?,
) -> BsdiffError {
  { kind, stage, block, offset, field, value, limit, }
}

///|
fn decode_int(
  data : Bytes,
  offset : Int32,
  stage : ErrorStage,
) -> Result[Int64, BsdiffError] {
  if offset < 0 || offset > data.length() || data.length() - offset < 8 {
    return Err(
      format_error(
        TruncatedData,
        stage,
        None,
        Some(offset.to_int64()),
        None,
        None,
        None,
      ),
    )
  }
  let mut magnitude = (data[offset + 7].to_int() & 127).to_int64()
  for i = 6; i >= 0; i = i - 1 {
    magnitude = magnitude * 256L + data[offset + i].to_int().to_int64()
  }
  if (data[offset + 7].to_int() & 128) != 0 {
    Ok(-magnitude)
  } else {
    Ok(magnitude)
  }
}

///|
// Used by the later patch generator.
#warnings("-unused_value")
fn encode_int(value : Int64) -> Result[Bytes, BsdiffError] {
  if value == -9223372036854775807L - 1L {
    return Err(
      format_error(IntegerOverflow, Header, None, None, None, Some(value), None),
    )
  }
  let negative = value < 0L
  let mut magnitude = if negative { -value } else { value }
  let bytes : Array[Byte] = []
  for _ in 0..<8 {
    bytes.push((magnitude % 256L).to_int().to_byte())
    magnitude = magnitude / 256L
  }
  if negative {
    bytes[7] = (bytes[7].to_int() | 128).to_byte()
  }
  Ok(Bytes::from_array(bytes))
}
