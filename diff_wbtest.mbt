///|
test "diff-checked-size-preflights" {
  assert_eq(generated_patch_size(14L, 14L, 14L, 74L), Ok(74))
  for
    (c, d, e, cap, kind) in [
      (14L, 14L, 14L, 73L, ResourceLimitExceeded),
      (-1L, 14L, 14L, 100L, IntegerOverflow),
      (2147483647L, 0L, 0L, 2147483647L, IntegerOverflow),
      (0L, 2147483615L, 1L, 2147483647L, IntegerOverflow),
    ] {
    match generated_patch_size(c, d, e, cap) {
      Ok(_) => abort("invalid size accepted")
      Err(error) => {
        assert_eq(error.kind, kind)
        assert_eq(error.stage, Header)
      }
    }
  }
  assert_eq(raw_control_size(2L, 3L, 4L, 55L), Ok(48))
  match raw_control_size(2L, 3L, 4L, 54L) {
    Ok(_) => abort("raw limit bypassed")
    Err(e) => assert_eq(e.kind, ResourceLimitExceeded)
  }
  match raw_control_size(9223372036854775807L, 0L, 0L, 9223372036854775807L) {
    Ok(_) => abort("control product overflow")
    Err(e) => assert_eq(e.kind, IntegerOverflow)
  }
}

///|
test "diff-residual-modulo-and-plan-validation" {
  let limits = Limits::for_apply()
  let old = b"\xff"
  let new = b"\x00"
  let raw = match
    encode_plan(
      old,
      new,
      [
        {
          new_start: 0,
          old_start: 0,
          diff_length: 1,
          extra_length: 0,
          seek: 0L,
        },
      ],
      limits,
      matching_test_budget(1000000L),
    ) {
    Ok(v) => v
    Err(_) => abort("valid plan rejected")
  }
  assert_eq(raw.difference, b"\x01")
  assert_eq(raw.extra, b"")
  assert_eq(decode_int(raw.control, 0, Control), Ok(1L))
  for
    segment in [
      { new_start: 1, old_start: 0, diff_length: 1, extra_length: 0, seek: 0L, },
      { new_start: 0, old_start: 0, diff_length: 2, extra_length: 0, seek: 0L, },
      {
        new_start: 0,
        old_start: 0,
        diff_length: 1,
        extra_length: 0,
        seek: 9223372036854775807L,
      },
    ] {
    match
      encode_plan(old, new, [segment], limits, matching_test_budget(1000000L)) {
      Ok(_) => abort("bad plan accepted")
      Err(e) => assert_eq(e.stage, Control)
    }
  }
}

///|
test "diff-public-residual-wrap" {
  let limits = {
    ..Limits::for_apply(),
    max_sort_work: 1000000L,
    max_match_work: 1000000L,
  }
  let old = Bytes::from_array(Array::make(32, b'\xff'))
  let bytes = old.to_array()
  bytes[0] = b'\x00'
  let new = Bytes::from_array(bytes)
  let patch = match diff(old, new, limits) {
    Ok(v) => v
    Err(_) => abort("generation failed")
  }
  let ranges = match parse_header(patch, limits) {
    Ok(v) => v
    Err(_) => abort("generated header failed")
  }
  let budget = match decompression_budget(limits) {
    Ok(v) => v
    Err(_) => abort("budget failed")
  }
  let raw = match
    decompress_block(
      patch[ranges.control_end:ranges.diff_end].to_owned(),
      32L,
      budget,
      Diff,
      ranges.control_end.to_int64(),
    ) {
    Ok(v) => v
    Err(_) => abort("generated diff stream failed")
  }
  assert_eq(raw.length(), 32)
  assert_eq(raw[0], b'\x01')
  for i in 1..<32 {
    assert_eq(raw[i], b'\x00')
  }
  assert_eq(apply(old, patch, limits), Ok(new))
}
