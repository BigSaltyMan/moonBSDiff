///|
/// Standard BSDIFF40 patch and its separate schema 1 JSON manifest.
pub struct PatchBundle {
  patch : Bytes
  manifest : Bytes
}

///|
/// Generate a patch and its manifest using the default generation options.
pub fn diff(
  old : Bytes,
  new : Bytes,
  limits : @moonbsdiff.Limits,
) -> Result[PatchBundle, @moonbsdiff.BsdiffError] {
  diff_with_options(old, new, limits, @moonbsdiff.DiffOptions::default())
}

///|
/// Generate a single patch, then hash the exact inputs and returned patch.
pub fn diff_with_options(
  old : Bytes,
  new : Bytes,
  limits : @moonbsdiff.Limits,
  options : @moonbsdiff.DiffOptions,
) -> Result[PatchBundle, @moonbsdiff.BsdiffError] {
  @moonbsdiff.diff_with_options(old, new, limits, options).map(patch => {
    patch,
    manifest: @manifest_support.make_manifest(old, new, patch),
  })
}
