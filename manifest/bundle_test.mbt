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
