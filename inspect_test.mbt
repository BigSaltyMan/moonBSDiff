///|
test "inspect public metadata is structural and Int64 exact" {
  let header = b"BSDIFF40" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"\xff\xff\xff\xff\xff\xff\xff\x7f"
  let info = match @moonbsdiff.inspect_header(header, 32L) {
    Ok(value) => value
    Err(_) => abort("structural-only inspection failed")
  }
  assert_eq(info.patch_bytes, 32L)
  assert_eq(info.new_bytes, 9223372036854775807L)
  assert_eq(info.control_start, 32L)
  assert_eq(info.control_length, 0L)
  assert_eq(info.diff_start, 32L)
  assert_eq(info.diff_length, 0L)
  assert_eq(info.extra_start, 32L)
  assert_eq(info.extra_length, 0L)
  for cap in [0L, -1L, 2147483648L] {
    match @moonbsdiff.inspect_header(header, cap) {
      Err(e) => {
        assert_eq(e.kind, @moonbsdiff.InvalidConfiguration)
        assert_eq(e.stage, @moonbsdiff.Configuration)
        assert_eq(e.field, Some("max_patch_bytes"))
        assert_eq(e.value, Some(cap))
        assert_eq(e.limit, Some(2147483647L))
        assert_eq(e.offset, None)
      }
      Ok(_) => abort("invalid inspection cap accepted")
    }
  }
  match @moonbsdiff.inspect_header(header, 31L) {
    Err(e) => {
      assert_eq(e.kind, @moonbsdiff.ResourceLimitExceeded)
      assert_eq(e.field, Some("max_patch_bytes"))
      assert_eq(e.value, Some(32L))
      assert_eq(e.limit, Some(31L))
    }
    Ok(_) => abort("patch cap ignored")
  }
}
