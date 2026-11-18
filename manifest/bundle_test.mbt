///|
fn publish_update(
  old : Bytes,
  new : Bytes,
) -> Result[@manifest.PatchBundle, @moonbsdiff.BsdiffError] {
  @manifest.diff(old, new, @moonbsdiff.Limits::for_diff())
}

///|
fn restore_bundle(
  old : Bytes,
  patch : Bytes,
  trusted_manifest : Bytes,
) -> Result[Bytes, @manifest.ManifestError] {
  @manifest.apply(old, patch, trusted_manifest, @moonbsdiff.Limits::for_apply())
}

///|
fn bundle_or_abort(
  result : Result[@manifest.PatchBundle, @moonbsdiff.BsdiffError],
) -> @manifest.PatchBundle {
  match result {
    Ok(bundle) => bundle
    Err(error) => abort(@debug.to_string(error))
  }
}

///|
test "manifest public bundle round trip" {
  let old = b"abc\x00\xff"
  let new = b"abC\x00\xff!"
  let bundle = bundle_or_abort(publish_update(old, new))
  assert_eq(bundle.patch[:8].to_owned(), b"BSDIFF40")
  assert_eq(restore_bundle(old, bundle.patch, bundle.manifest), Ok(new))
}

///|
fn bundle_hex(bytes : Bytes) -> String {
  let output = StringBuilder(size_hint=bytes.length() * 2)
  for byte in bytes {
    output.write_string(byte.to_hex())
  }
  output.to_string()
}

///|
test "manifest public bundle index two targets" {
  let old = b"ABCDE"
  let new_a = b"ABXDE"
  let new_b = b"prefix-ABCDE!"
  let limits = @moonbsdiff.Limits::for_diff()
  let index = @manifest.BundleIndex::build(old, limits).unwrap()
  let bundle_a = index.diff(new_a, limits).unwrap()
  let bundle_b = index.diff(new_b, limits).unwrap()
  // Read the first bundle only after generating the second.
  let apply_limits = @moonbsdiff.Limits::for_apply()
  assert_eq(
    @manifest.apply(old, bundle_a.patch, bundle_a.manifest, apply_limits),
    Ok(new_a),
  )
  assert_eq(
    @manifest.apply(old, bundle_b.patch, bundle_b.manifest, apply_limits),
    Ok(new_b),
  )
}

///|
test "manifest bundle index budgets and options" {
  let old = b"ABCDE"
  let new = b"ABXDE"
  let limits = @moonbsdiff.Limits::for_diff()
  let reuse = { ..limits, max_sort_work: 1L, }
  match @manifest.BundleIndex::build(old, reuse) {
    Ok(_) => abort("insufficient sorting budget built an index")
    Err(error) => {
      assert_eq(error, @moonbsdiff.DiffIndex::build(old, reuse).unwrap_err())
      assert_eq(error.kind, @moonbsdiff.ResourceLimitExceeded)
      assert_eq(error.stage, @moonbsdiff.Sorting)
      assert_eq(error.field, Some("sort_remaining"))
      assert_eq(error.value, Some(281L))
      assert_eq(error.limit, Some(1L))
    }
  }
  let index = @manifest.BundleIndex::build(old, limits).unwrap()
  let options : @moonbsdiff.DiffOptions = { compression_level: 1, }
  let indexed = bundle_or_abort(index.diff_with_options(new, reuse, options))
  let single = bundle_or_abort(
    @manifest.diff_with_options(old, new, limits, options),
  )
  assert_eq(indexed.patch, single.patch)
  assert_eq(indexed.manifest, single.manifest)

  let restricted = { ..reuse, max_old_bytes: 4L, }
  match index.diff_with_options(new, restricted, options) {
    Ok(_) => abort("indexed generation ignored its old input limit")
    Err(error) => {
      assert_eq(error.kind, @moonbsdiff.ResourceLimitExceeded)
      assert_eq(error.stage, @moonbsdiff.Header)
      assert_eq(error.field, Some("max_old_bytes"))
      assert_eq(error.value, Some(5L))
      assert_eq(error.limit, Some(4L))
    }
  }
  let retried = bundle_or_abort(index.diff_with_options(new, reuse, options))
  assert_eq(retried.patch, indexed.patch)
  assert_eq(retried.manifest, indexed.manifest)
}

///|
test "manifest bundle matches root options" {
  let old = b"abc\x00\xff"
  let new = b"abC\x00\xff!"
  let limits = @moonbsdiff.Limits::for_diff()
  let default = bundle_or_abort(@manifest.diff(old, new, limits))
  assert_eq(Ok(default.patch), @moonbsdiff.diff(old, new, limits))
  let options : @moonbsdiff.DiffOptions = { compression_level: 1, }
  let explicit = bundle_or_abort(
    @manifest.diff_with_options(old, new, limits, options),
  )
  assert_eq(
    Ok(explicit.patch),
    @moonbsdiff.diff_with_options(old, new, limits, options),
  )
  assert_true(explicit.patch != default.patch)

  let invalid : @moonbsdiff.DiffOptions = { compression_level: 10, }
  match @manifest.diff_with_options(old, new, limits, invalid) {
    Ok(_) => abort("invalid level returned a bundle")
    Err(error) => {
      assert_eq(
        Err(error),
        @moonbsdiff.diff_with_options(old, new, limits, invalid),
      )
      assert_eq(error.kind, @moonbsdiff.InvalidConfiguration)
      assert_eq(error.stage, @moonbsdiff.Configuration)
      assert_eq(error.field, Some("compression_level"))
      assert_eq(error.value, Some(10L))
      assert_eq(error.limit, Some(9L))
    }
  }
  let restricted = { ..limits, max_sort_work: 1L, }
  match @manifest.diff(old, new, restricted) {
    Ok(_) => abort("sorting limit returned a bundle")
    Err(error) => {
      assert_eq(Err(error), @moonbsdiff.diff(old, new, restricted))
      assert_eq(error.kind, @moonbsdiff.ResourceLimitExceeded)
      assert_eq(error.stage, @moonbsdiff.Sorting)
    }
  }
  // The native CLI parity check consumes these public API outputs.
  println(
    "BUNDLE:\{bundle_hex(explicit.patch)}:\{bundle_hex(explicit.manifest)}",
  )
}
