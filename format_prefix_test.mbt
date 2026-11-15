///|
test "header prefix: shared bounds without buffering patch" {
  let header = b"BSDIFF40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  let info = @moonbsdiff.inspect_header_prefix(header, 100L, 100L).unwrap()
  assert_eq(info.extra_start, 32L)
  assert_eq(info.extra_length, 68L)
  assert_eq(info.patch_bytes, 100L)
  assert_eq(
    @moonbsdiff.inspect_header_prefix(header, 100L, 99L).unwrap_err().kind,
    ResourceLimitExceeded,
  )
  assert_eq(
    @moonbsdiff.inspect_header_prefix(header, 31L, 100L).unwrap_err().kind,
    InvalidField,
  )
}
