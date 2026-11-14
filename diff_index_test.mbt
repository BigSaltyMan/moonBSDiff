///|
fn index_build(
  old : Bytes,
  limits : @moonbsdiff.Limits,
) -> @moonbsdiff.DiffIndex {
  match @moonbsdiff.DiffIndex::build(old, limits) {
    Ok(index) => index
    Err(_) => abort("index construction failed")
  }
}

///|
fn index_patch(
  index : @moonbsdiff.DiffIndex,
  new : Bytes,
  limits : @moonbsdiff.Limits,
) -> Bytes {
  match index.diff(new, limits) {
    Ok(patch) => patch
    Err(_) => abort("indexed generation failed")
  }
}

///|
fn[T] index_error(
  result : Result[T, @moonbsdiff.BsdiffError],
  kind : @moonbsdiff.ErrorKind,
  stage : @moonbsdiff.ErrorStage,
  field : String,
  value : Int64,
  limit : Int64,
) -> Unit raise {
  match result {
    Ok(_) => abort("failure returned a partial result")
    Err(e) => {
      assert_eq(e.kind, kind)
      assert_eq(e.stage, stage)
      assert_eq(e.field, Some(field))
      assert_eq(e.value, Some(value))
      assert_eq(e.limit, Some(limit))
      assert_eq(e.block, None)
      assert_eq(e.offset, None)
    }
  }
}

///|
test "index-reuse-two-targets-and-safe-aliases" {
  let limits = @moonbsdiff.Limits::for_diff()
  let source = b"old\x00\xff-data".to_array()
  let old = Bytes::from_array(source)
  let index = index_build(old, limits)
  source[0] = b'X'
  assert_eq(old, b"old\x00\xff-data")
  let targets = [b"old\x00\xff-DATA!", b"prefix-old\x00\xff-data"]
  let reuse = { ..limits, max_sort_work: 1L, }
  for new in targets {
    let patch = index_patch(index, new, reuse)
    assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
    assert_eq(@moonbsdiff.diff(old, new, limits), Ok(patch))
    assert_eq(index_patch(index, new, reuse), patch)
    let returned_copy = patch.to_array()
    returned_copy[0] = b'!'
    assert_true(Bytes::from_array(returned_copy) != patch)
    assert_eq(index_patch(index, new, reuse), patch)
  }
  assert_eq(old, b"old\x00\xff-data")
  assert_eq(targets, [b"old\x00\xff-DATA!", b"prefix-old\x00\xff-data"])
}

///|
test "index-reuse-build-contract-and-no-resorting" {
  let limits = @moonbsdiff.Limits::for_diff()
  index_error(
    @moonbsdiff.DiffIndex::build(b"ABCDE", { ..limits, max_sort_work: 1L, }),
    @moonbsdiff.ResourceLimitExceeded,
    @moonbsdiff.Sorting,
    "sort_remaining",
    281L,
    1L,
  )
  index_error(
    @moonbsdiff.DiffIndex::build(b"ABCDE", { ..limits, max_old_bytes: 4L, }),
    @moonbsdiff.ResourceLimitExceeded,
    @moonbsdiff.Header,
    "max_old_bytes",
    5L,
    4L,
  )
  index_error(
    @moonbsdiff.DiffIndex::build(b"ABCDE", { ..limits, max_sort_work: 0L, }),
    @moonbsdiff.InvalidConfiguration,
    @moonbsdiff.Configuration,
    "max_sort_work",
    0L,
    9223372036854775807L,
  )
  // Construction has no target/patch/raw payload, so these valid positive
  // values impose no unrelated relation to old size.
  let build_limits = {
    ..limits,
    max_new_bytes: 1L,
    max_output_bytes: 1L,
    max_patch_bytes: 1L,
    max_decompressed_bytes: 1L,
    max_control_instructions: 1L,
    max_match_work: 1L,
  }
  let index = index_build(b"ABCDE", build_limits)
  let reuse = { ..limits, max_sort_work: 1L, }
  let patch = index_patch(index, b"ABXDE", reuse)
  assert_eq(@moonbsdiff.apply(b"ABCDE", patch, limits), Ok(b"ABXDE"))
  index_error(
    @moonbsdiff.diff(b"ABCDE", b"ABXDE", reuse),
    @moonbsdiff.ResourceLimitExceeded,
    @moonbsdiff.Sorting,
    "sort_remaining",
    281L,
    1L,
  )
}

///|
test "index-reuse-exact-per-call-budget-and-recovery" {
  let limits = @moonbsdiff.Limits::for_diff()
  let index = index_build(b"A", limits)
  let patch = index_patch(index, b"A", limits)
  // Existing generation reservation derivation for this fixture: scan/plan/raw
  // and stream calls = 53, compressed/final copies = 5*actual patch length.
  let cost = 53L + 5L * patch.length().to_int64()
  let exact = { ..limits, max_sort_work: 1L, max_match_work: cost, }
  assert_eq(index.diff(b"A", exact), Ok(patch))
  assert_eq(index.diff(b"A", exact), Ok(patch))
  index_error(
    index.diff(b"A", { ..exact, max_match_work: cost - 1L, }),
    @moonbsdiff.ResourceLimitExceeded,
    @moonbsdiff.Matching,
    "match_remaining",
    3L * patch.length().to_int64(),
    3L * patch.length().to_int64() - 1L,
  )
  assert_eq(index.diff(b"A", exact), Ok(patch))
  index_error(
    index.diff(b"A", { ..exact, max_match_work: 0L, }),
    @moonbsdiff.InvalidConfiguration,
    @moonbsdiff.Configuration,
    "max_match_work",
    0L,
    9223372036854775807L,
  )
  assert_eq(index.diff(b"A", exact), Ok(patch))
}

///|
test "index-reuse-target-caps-are-rechecked" {
  let limits = @moonbsdiff.Limits::for_diff()
  let index = index_build(b"ABCDE", limits)
  let patch = index_patch(index, b"ABXDE", limits)
  let size = patch.length().to_int64()
  for
    (bad, stage, field, value, cap) in [
      (
        { ..limits, max_old_bytes: 4L, },
        @moonbsdiff.Header,
        "max_old_bytes",
        5L,
        4L,
      ),
      (
        { ..limits, max_new_bytes: 4L, },
        @moonbsdiff.Header,
        "max_new_bytes",
        5L,
        4L,
      ),
      (
        { ..limits, max_output_bytes: 4L, },
        @moonbsdiff.Header,
        "max_output_bytes",
        5L,
        4L,
      ),
      (
        { ..limits, max_patch_bytes: size - 1L, },
        @moonbsdiff.Header,
        "max_patch_bytes",
        size,
        size - 1L,
      ),
      (
        { ..limits, max_decompressed_bytes: 28L, },
        @moonbsdiff.Control,
        "max_decompressed_bytes",
        29L,
        28L,
      ),
    ] {
    index_error(
      index.diff(b"ABXDE", bad),
      @moonbsdiff.ResourceLimitExceeded,
      stage,
      field,
      value,
      cap,
    )
    assert_eq(index.diff(b"ABXDE", limits), Ok(patch))
  }
  assert_eq(@moonbsdiff.apply(b"ABCDE", patch, limits), Ok(b"ABXDE"))
}

///|
test "index-reuse-empty-old-and-empty-target" {
  let limits = @moonbsdiff.Limits::for_diff()
  let index = index_build(b"", { ..limits, max_sort_work: 1L, })
  for new in [b"", b"x\x00\xff"] {
    let patch = index_patch(index, new, limits)
    assert_eq(@moonbsdiff.apply(b"", patch, limits), Ok(new))
    assert_eq(@moonbsdiff.diff(b"", new, limits), Ok(patch))
  }
}
