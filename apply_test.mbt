///|
fn apply_limits() -> @moonbsdiff.Limits {
  @moonbsdiff.Limits::for_apply()
}

///|
test "apply-error-absolute-block-locations" {
  let patch = apply_fixture_13_patch()
  // This fixed, compact Python fixture has one-byte compressed length fields.
  for i in 9..<16 {
    assert_eq(patch[i], b'\x00')
  }
  for i in 17..<24 {
    assert_eq(patch[i], b'\x00')
  }
  let control_end = 32 + patch[8].to_int()
  let diff_end = control_end + patch[16].to_int()
  for
    (start, stage, block) in [
      (32, @moonbsdiff.Control, "control"),
      (control_end, @moonbsdiff.Diff, "diff"),
      (diff_end, @moonbsdiff.Extra, "extra"),
    ] {
    let wrong = patch.to_array()
    wrong[start] = b'X'
    match @moonbsdiff.apply(b"\xff", Bytes::from_array(wrong), apply_limits()) {
      Ok(_) => abort("invalid compressed header accepted")
      Err(e) => {
        assert_eq(e.kind, InvalidField)
        assert_eq(e.stage, stage)
        assert_eq(e.block, Some(block))
        assert_eq(e.offset, Some(start.to_int64()))
        assert_eq(e.field, Some("invalid bzip2 header"))
      }
    }
  }
}

///|
test "apply-memory-example" {
  let stream = b"BZh9\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
  let patch = b"BSDIFF40" +
    b"\x0e\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" +
    stream +
    stream +
    stream
  let limits : @moonbsdiff.Limits = {
    max_old_bytes: 1024L,
    max_new_bytes: 1024L,
    max_patch_bytes: 1024L,
    max_output_bytes: 1024L,
    max_decompressed_bytes: 4096L,
    max_control_instructions: 128L,
    max_sort_work: 1L,
    max_match_work: 1L,
  }
  assert_eq(@moonbsdiff.apply(b"", patch, limits), Ok(b""))
}
