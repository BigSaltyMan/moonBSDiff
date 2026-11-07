///|
fn diff_test_limits() -> @moonbsdiff.Limits {
  {
    max_old_bytes: 10000L,
    max_new_bytes: 10000L,
    max_patch_bytes: 20000L,
    max_output_bytes: 10000L,
    max_decompressed_bytes: 50000L,
    max_control_instructions: 1000L,
    max_sort_work: 10000000L,
    max_match_work: 10000000L,
  }
}

///|
fn diff_test_get(
  old : Bytes,
  new : Bytes,
  limits : @moonbsdiff.Limits,
) -> Bytes {
  match @moonbsdiff.diff(old, new, limits) {
    Ok(b) => b
    Err(_) => abort("diff failed")
  }
}

///|
fn diff_test_run(name : String, old : Bytes, new : Bytes) -> Unit {
  let old_snapshot = old.to_array()
  let new_snapshot = new.to_array()
  let limits = diff_test_limits()
  let patch = diff_test_get(old, new, limits)
  try! assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
  try! assert_eq(diff_test_get(old, new, limits), patch)
  try! assert_eq(old.to_array(), old_snapshot)
  try! assert_eq(new.to_array(), new_snapshot)
  let digits = b"0123456789abcdef"
  let text = StringBuilder()
  for byte in patch {
    text.write_char(digits[byte.to_int() / 16].to_int().to_char().unwrap())
    text.write_char(digits[byte.to_int() % 16].to_int().to_char().unwrap())
  }
  println("DIFF:\{name}:\{text.to_string()}")
}

///|
test "diff-state-isolation" {
  let limits = diff_test_limits()
  let old = b"abcdefghijklmnopabcdefghijklmnop"
  let new = b"abcdefghijklmnop!bcdefghijklmnop"
  let first = diff_test_get(old, new, limits)
  let snapshot = first.to_array()
  let independent = diff_test_get(old, new, limits)
  let copy = first.to_array()
  copy[0] = b'X'
  assert_eq(first.to_array(), snapshot)
  assert_eq(independent, first)
  let other = diff_test_get(b"AAAA", b"zzzz", limits)
  assert_eq(@moonbsdiff.apply(b"AAAA", other, limits), Ok(b"zzzz"))
  let prefix = b"abcdefghijklmnop"
  let truncated = diff_test_get(old, prefix, limits)
  assert_eq(@moonbsdiff.apply(old, truncated, limits), Ok(prefix))
  assert_eq(diff_test_get(old, new, limits), first)
}

///|
test "diff-limits-and-recovery" {
  let limits = diff_test_limits()
  let old = b"ABC"
  let new = b"AXC"
  let old_snapshot = old.to_array()
  let new_snapshot = new.to_array()
  for
    (bad, kind, stage, field) in [
      (
        { ..limits, max_old_bytes: 1L, },
        @moonbsdiff.ResourceLimitExceeded,
        @moonbsdiff.Header,
        "max_old_bytes",
      ),
      (
        { ..limits, max_new_bytes: 1L, },
        ResourceLimitExceeded,
        Header,
        "max_new_bytes",
      ),
      (
        { ..limits, max_output_bytes: 1L, },
        ResourceLimitExceeded,
        Header,
        "max_output_bytes",
      ),
      (
        { ..limits, max_patch_bytes: 73L, },
        ResourceLimitExceeded,
        Header,
        "max_patch_bytes",
      ),
      (
        { ..limits, max_patch_bytes: 74L, },
        ResourceLimitExceeded,
        Header,
        "max_patch_bytes",
      ),
      (
        { ..limits, max_sort_work: 1L, },
        ResourceLimitExceeded,
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
        { ..limits, max_old_bytes: 0L, },
        @moonbsdiff.InvalidConfiguration,
        @moonbsdiff.Configuration,
        "max_old_bytes",
      ),
    ] {
    match @moonbsdiff.diff(old, new, bad) {
      Ok(_) => abort("limit bypassed")
      Err(e) => {
        assert_eq(e.kind, kind)
        assert_eq(e.stage, stage)
        assert_eq(e.field, Some(field))
      }
    }
    assert_eq(old.to_array(), old_snapshot)
    assert_eq(new.to_array(), new_snapshot)
    let patch = diff_test_get(b"ABC", b"AXC", limits)
    assert_eq(@moonbsdiff.apply(b"ABC", patch, limits), Ok(b"AXC"))
  }
  let empty = diff_test_get(b"", b"", { ..limits, max_patch_bytes: 74L, })
  assert_eq(empty.length(), 74)
}

///|
test "diff-memory-example" {
  let limits : @moonbsdiff.Limits = {
    max_old_bytes: 4096L,
    max_new_bytes: 4096L,
    max_patch_bytes: 8192L,
    max_output_bytes: 4096L,
    max_decompressed_bytes: 16384L,
    max_control_instructions: 256L,
    max_sort_work: 1000000L,
    max_match_work: 1000000L,
  }
  let old = b"MoonBSDiff example version 1"
  let new = b"MoonBSDiff example version 2!"
  let patch = match @moonbsdiff.diff(old, new, limits) {
    Ok(b) => b
    Err(_) => abort("diff failed")
  }
  assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
}

///|
test "diff-instruction-limit" {
  let limits = diff_test_limits()
  let old = b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  let new = b"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  match
    @moonbsdiff.diff(old, new, { ..limits, max_control_instructions: 1L, }) {
    Ok(_) => abort("control count limit bypassed")
    Err(e) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Matching)
      assert_eq(e.field, Some("segments"))
    }
  }
  let patch = diff_test_get(old, new, limits)
  assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
}
