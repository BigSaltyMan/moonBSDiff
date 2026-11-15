///|
fn options_get(result : Result[Bytes, @moonbsdiff.BsdiffError]) -> Bytes {
  match result {
    Ok(p) => p
    Err(_) => abort("generation options failed")
  }
}

///|
fn options_index(old : Bytes) -> @moonbsdiff.DiffIndex {
  match @moonbsdiff.DiffIndex::build(old, @moonbsdiff.Limits::for_diff()) {
    Ok(i) => i
    Err(_) => abort("options index build failed")
  }
}

///|
fn options_streams(patch : Bytes, level : Int32) -> Unit raise {
  let info = match @moonbsdiff.inspect_header(patch, 131072L) {
    Ok(i) => i
    Err(_) => abort("options header")
  }
  for start in [info.control_start, info.diff_start, info.extra_start] {
    let at = start.to_int()
    assert_eq(patch[at:at + 3].to_owned(), b"BZh")
    assert_eq(patch[at + 3].to_int(), 48 + level)
  }
}

///|
test "options-compact-levels-one-through-nine" {
  let old = b"abracadabra\x00\xff"
  let new = b"abraCHANGED\x00\xffabracadabra!"
  let limits = @moonbsdiff.Limits::for_diff()
  let index = options_index(old)
  for level in 1..<=9 {
    let options : @moonbsdiff.DiffOptions = { compression_level: level, }
    assert_eq(options.validate(), Ok(()))
    let patch = options_get(
      @moonbsdiff.diff_with_options(old, new, limits, options),
    )
    options_streams(patch, level)
    assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
    assert_eq(index.diff_with_options(new, limits, options), Ok(patch))
    assert_eq(
      @moonbsdiff.diff_with_options(old, new, limits, options),
      Ok(patch),
    )
  }
  assert_eq(old, b"abracadabra\x00\xff")
  assert_eq(new, b"abraCHANGED\x00\xffabracadabra!")
}

///|
test "options-compact-default-nine-and-empty-streams" {
  let limits = @moonbsdiff.Limits::for_diff()
  let options = @moonbsdiff.DiffOptions::default()
  assert_eq(options.compression_level, 9)
  let old = b"abc\x00\xff"
  let new = b"abC\x00\xff!"
  let patch = options_get(@moonbsdiff.diff(old, new, limits))
  assert_eq(@moonbsdiff.diff_with_options(old, new, limits, options), Ok(patch))
  let index = options_index(old)
  assert_eq(index.diff(new, limits), Ok(patch))
  assert_eq(index.diff_with_options(new, limits, options), Ok(patch))
  for level in [1, 9] {
    let patch = options_get(
      @moonbsdiff.diff_with_options(b"", b"", limits, {
        compression_level: level,
      }),
    )
    options_streams(patch, level)
    assert_eq(@moonbsdiff.apply(b"", patch, limits), Ok(b""))
  }
}

///|
test "options-compact-invalid-before-work-and-index-recovery" {
  let limits = @moonbsdiff.Limits::for_diff()
  let index = options_index(b"ABCDE")
  for level in [-2147483648, -1, 0, 10, 2147483647] {
    let options : @moonbsdiff.DiffOptions = { compression_level: level, }
    for
      result in [
        @moonbsdiff.diff_with_options(
          b"ABCDE",
          b"ABXDE",
          { ..limits, max_sort_work: 1L, },
          options,
        ),
        index.diff_with_options(
          b"ABXDE",
          { ..limits, max_match_work: 1L, },
          options,
        ),
      ] {
      match result {
        Ok(_) => abort("invalid level returned a patch")
        Err(e) => {
          assert_eq(e.kind, @moonbsdiff.InvalidConfiguration)
          assert_eq(e.stage, @moonbsdiff.Configuration)
          assert_eq(e.field, Some("compression_level"))
          assert_eq(e.value, Some(level.to_int64()))
          assert_eq(e.limit, Some(9L))
          assert_eq(e.block, None)
          assert_eq(e.offset, None)
        }
      }
    }
  }
  let options : @moonbsdiff.DiffOptions = { compression_level: 1, }
  let patch = options_get(index.diff_with_options(b"ABXDE", limits, options))
  match
    index.diff_with_options(
      b"ABXDE",
      { ..limits, max_patch_bytes: patch.length().to_int64() - 1L, },
      options,
    ) {
    Ok(_) => abort("patch quota was ignored")
    Err(e) => {
      assert_eq(e.kind, @moonbsdiff.ResourceLimitExceeded)
      assert_eq(e.stage, @moonbsdiff.Header)
      assert_eq(e.field, Some("max_patch_bytes"))
      assert_eq(e.value, Some(patch.length().to_int64()))
      assert_eq(e.limit, Some(patch.length().to_int64() - 1L))
      assert_eq(e.offset, None)
      assert_eq(e.block, None)
    }
  }
  assert_eq(index.diff_with_options(b"ABXDE", limits, options), Ok(patch))
  assert_eq(@moonbsdiff.apply(b"ABCDE", patch, limits), Ok(b"ABXDE"))
}
