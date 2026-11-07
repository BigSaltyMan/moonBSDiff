///|
test "diff-resource-compact-public-defaults-isolation" {
  let limits = @moonbsdiff.Limits::for_diff()
  assert_eq(limits.validate(), Ok(()))
  assert_eq(limits.max_old_bytes, 65536L)
  assert_eq(limits.max_new_bytes, 65536L)
  assert_eq(limits.max_output_bytes, 65536L)
  assert_eq(limits.max_patch_bytes, 131072L)
  assert_eq(limits.max_decompressed_bytes, 262144L)
  assert_eq(limits.max_control_instructions, 4096L)
  assert_eq(limits.max_sort_work, 8388608L)
  assert_eq(limits.max_match_work, 8388608L)
  assert_eq(@moonbsdiff.Limits::for_apply().max_sort_work, 1L)
  assert_eq(@moonbsdiff.Limits::for_apply().max_match_work, 1L)
  let old = b"banana\x00\xffbanana"
  let new = b"banana\x00\xffBANANA!"
  let old_snapshot = old.to_array()
  let new_snapshot = new.to_array()
  let first = match @moonbsdiff.diff(old, new, limits) {
    Ok(v) => v
    Err(_) => abort("default generation failed")
  }
  let snapshot = first.to_array()
  // Bytes is immutable. Mutate the caller's extracted array and construct a
  // damaged result independently; neither can mutate the next call's storage.
  let array = first.to_array()
  array[0] = b'X'
  let damaged = Bytes::from_array(array)
  assert_true(damaged != first)
  assert_eq(first.to_array(), snapshot)
  for
    (bad, kind, stage, field) in [
      (
        { ..limits, max_sort_work: 1L, },
        @moonbsdiff.ResourceLimitExceeded,
        @moonbsdiff.Sorting,
        "sort_remaining",
      ),
      (
        { ..limits, max_match_work: 1L, },
        ResourceLimitExceeded,
        @moonbsdiff.Matching,
        "match_remaining",
      ),
      (
        { ..limits, max_decompressed_bytes: 1L, },
        ResourceLimitExceeded,
        @moonbsdiff.Control,
        "max_decompressed_bytes",
      ),
      (
        { ..limits, max_patch_bytes: 74L, },
        ResourceLimitExceeded,
        @moonbsdiff.Header,
        "max_patch_bytes",
      ),
      (
        { ..limits, max_new_bytes: 0L, },
        @moonbsdiff.InvalidConfiguration,
        @moonbsdiff.Configuration,
        "max_new_bytes",
      ),
      (
        { ..limits, max_new_bytes: -1L, },
        InvalidConfiguration,
        Configuration,
        "max_new_bytes",
      ),
    ] {
    match @moonbsdiff.diff(old, new, bad) {
      Ok(_) => abort("failure expected")
      Err(e) => {
        assert_eq(e.kind, kind)
        assert_eq(e.stage, stage)
        assert_eq(e.field, Some(field))
        assert_eq(e.offset, None)
      }
    }
    assert_eq(@moonbsdiff.diff(old, new, limits), Ok(first))
    assert_eq(old.to_array(), old_snapshot)
    assert_eq(new.to_array(), new_snapshot)
  }
  let other = match @moonbsdiff.diff(b"", b"new", limits) {
    Ok(v) => v
    Err(_) => abort("independent call")
  }
  assert_eq(@moonbsdiff.apply(b"", other, limits), Ok(b"new"))
  assert_eq(@moonbsdiff.diff(old, new, limits), Ok(first))
  assert_eq(@moonbsdiff.apply(old, first, limits), Ok(new))
}
