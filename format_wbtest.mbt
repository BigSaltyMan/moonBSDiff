///|
fn test_limits() -> Limits {
  {
    max_old_bytes: 1024L,
    max_new_bytes: 1024L,
    max_patch_bytes: 1024L,
    max_output_bytes: 1024L,
    max_decompressed_bytes: 1024L,
    max_control_instructions: 1024L,
    max_sort_work: 1024L,
    max_match_work: 1024L,
  }
}

///|
fn expect_failure(
  data : Bytes,
  limits : Limits,
  kind : ErrorKind,
  stage : ErrorStage,
  block : String?,
  offset : Int64?,
  field : String?,
) -> Unit {
  match parse_header(data, limits) {
    Err(e) => {
      try! assert_eq(e.kind, kind)
      try! assert_eq(e.stage, stage)
      try! assert_eq(e.block, block)
      try! assert_eq(e.offset, offset)
      try! assert_eq(e.field, field)
    }
    Ok(_) => abort("expected failure")
  }
}

///|
test "fixed integer vectors" {
  assert_eq(encode_int(0L), Ok(b"\x00\x00\x00\x00\x00\x00\x00\x00"))
  assert_eq(decode_int(b"\x00\x00\x00\x00\x00\x00\x00\x00", 0, Header), Ok(0L))
  assert_eq(encode_int(1L), Ok(b"\x01\x00\x00\x00\x00\x00\x00\x00"))
  assert_eq(decode_int(b"\x01\x00\x00\x00\x00\x00\x00\x00", 0, Header), Ok(1L))
  assert_eq(encode_int(-1L), Ok(b"\x01\x00\x00\x00\x00\x00\x00\x80"))
  assert_eq(decode_int(b"\x01\x00\x00\x00\x00\x00\x00\x80", 0, Header), Ok(-1L))
  assert_eq(encode_int(255L), Ok(b"\xff\x00\x00\x00\x00\x00\x00\x00"))
  assert_eq(
    decode_int(b"\xff\x00\x00\x00\x00\x00\x00\x00", 0, Header),
    Ok(255L),
  )
  assert_eq(encode_int(-255L), Ok(b"\xff\x00\x00\x00\x00\x00\x00\x80"))
  assert_eq(
    decode_int(b"\xff\x00\x00\x00\x00\x00\x00\x80", 0, Header),
    Ok(-255L),
  )
  assert_eq(encode_int(256L), Ok(b"\x00\x01\x00\x00\x00\x00\x00\x00"))
  assert_eq(
    decode_int(b"\x00\x01\x00\x00\x00\x00\x00\x00", 0, Header),
    Ok(256L),
  )
  assert_eq(encode_int(-256L), Ok(b"\x00\x01\x00\x00\x00\x00\x00\x80"))
  assert_eq(
    decode_int(b"\x00\x01\x00\x00\x00\x00\x00\x80", 0, Header),
    Ok(-256L),
  )
  assert_eq(
    encode_int(9223372036854775807L),
    Ok(b"\xff\xff\xff\xff\xff\xff\xff\x7f"),
  )
  assert_eq(
    decode_int(b"\xff\xff\xff\xff\xff\xff\xff\x7f", 0, Header),
    Ok(9223372036854775807L),
  )
  assert_eq(
    encode_int(-9223372036854775807L),
    Ok(b"\xff\xff\xff\xff\xff\xff\xff\xff"),
  )
  assert_eq(
    decode_int(b"\xff\xff\xff\xff\xff\xff\xff\xff", 0, Header),
    Ok(-9223372036854775807L),
  )
  assert_eq(decode_int(b"\x00\x00\x00\x00\x00\x00\x00\x80", 0, Header), Ok(0L))
}

///|
test "integer errors and offsets" {
  let min = -9223372036854775807L - 1L
  match encode_int(min) {
    Err(e) => {
      assert_eq(e.kind, IntegerOverflow)
      assert_eq(e.stage, Header)
      assert_eq(e.value, Some(min))
    }
    Ok(_) => abort("minimum encoded")
  }
  let bytes = b"\xff\x01\x00\x00\x00\x00\x00\x00\x00"
  assert_eq(decode_int(bytes, 1, Control), Ok(1L))
  for offset in [-1, 2, 9, 2147483647] {
    match decode_int(bytes, offset, Control) {
      Err(e) => {
        assert_eq(e.kind, TruncatedData)
        assert_eq(e.stage, Control)
        assert_eq(e.offset, Some(offset.to_int64()))
      }
      Ok(_) => abort("out of range decoded")
    }
  }
  match decode_int(b"\x00\x00\x00\x00\x00\x00\x00", 0, Header) {
    Err(e) => assert_eq(e.kind, TruncatedData)
    Ok(_) => abort("short decoded")
  }
}

///|
test "short headers and unsupported magic" {
  for n in 0..<32 {
    let bytes = Bytes::from_array(Array::make(n, (0).to_byte()))
    expect_failure(
      bytes,
      test_limits(),
      TruncatedData,
      Header,
      None,
      Some(n.to_int64()),
      None,
    )
  }
  expect_failure(
    b"BSDIFF43\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    test_limits(),
    UnsupportedFormat,
    Header,
    None,
    Some(7L),
    Some("magic"),
  )
}

///|
test "valid block boundaries and negative zero" {
  let patch = b"BSDIFF40\x02\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00abcdeXYZ"
  match parse_header(patch, test_limits()) {
    Err(_) => abort("valid header rejected")
    Ok(r) => {
      assert_eq(r.control_start, 32)
      assert_eq(r.control_end, 34)
      assert_eq(r.diff_end, 37)
      assert_eq(r.extra_end, 40)
      assert_eq(r.new_size, 0L)
    }
  }
  let zero = b"BSDIFF40\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x80"
  match parse_header(zero, test_limits()) {
    Err(_) => abort("negative zero rejected")
    Ok(r) => {
      assert_eq(r.control_end, 32)
      assert_eq(r.diff_end, 32)
      assert_eq(r.extra_end, 32)
      assert_eq(r.new_size, 0L)
    }
  }
}

///|
test "invalid fields and ranges" {
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\x01\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    test_limits(),
    InvalidField,
    Header,
    None,
    Some(8L),
    Some("control_length"),
  )
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00",
    test_limits(),
    InvalidField,
    Header,
    None,
    Some(16L),
    Some("diff_length"),
  )
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x80",
    test_limits(),
    InvalidField,
    Header,
    None,
    Some(24L),
    Some("new_size"),
  )
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\xff\xff\xff\xff\xff\xff\xff\x7f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    test_limits(),
    IntegerOverflow,
    Header,
    Some("control"),
    Some(8L),
    Some("control_length"),
  )
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\x01\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\x7f\x00\x00\x00\x00\x00\x00\x00\x00",
    test_limits(),
    IntegerOverflow,
    Header,
    Some("diff"),
    Some(16L),
    Some("diff_length"),
  )
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    test_limits(),
    TruncatedData,
    Header,
    Some("control"),
    Some(8L),
    Some("control_length"),
  )
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
    test_limits(),
    TruncatedData,
    Header,
    Some("diff"),
    Some(16L),
    Some("diff_length"),
  )
}

///|
test "limits precede parsing and output allocation" {
  let zero = b"BSDIFF40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  let invalid = { ..test_limits(), max_patch_bytes: 0L, }
  expect_failure(
    zero,
    invalid,
    InvalidConfiguration,
    Configuration,
    None,
    None,
    Some("max_patch_bytes"),
  )
  let tiny = { ..test_limits(), max_patch_bytes: 31L, }
  expect_failure(
    zero,
    tiny,
    ResourceLimitExceeded,
    Header,
    None,
    None,
    Some("max_patch_bytes"),
  )
  expect_failure(
    b"\x42\x53\x44\x49\x46\x46\x34\x30\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff\xff\xff\xff\x7f",
    test_limits(),
    ResourceLimitExceeded,
    Header,
    None,
    Some(24L),
    Some("max_output_bytes"),
  )
}

///|
test "nonempty blocks end exactly at patch end" {
  let patch = b"BSDIFF40\x02\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00abcde"
  let limits = { ..test_limits(), max_patch_bytes: 37L, max_output_bytes: 1L, }
  match parse_header(patch, limits) {
    Err(_) => abort("exact boundary rejected")
    Ok(r) => {
      assert_eq(r.control_start, 32)
      assert_eq(r.control_end, 34)
      assert_eq(r.diff_end, 37)
      assert_eq(r.extra_end, 37)
      assert_eq(r.new_size, 1L)
    }
  }
}
