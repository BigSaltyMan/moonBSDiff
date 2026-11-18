///|
/// Reusable root index and the manifest identity of its immutable old bytes.
pub struct BundleIndex {
  priv index : @moonbsdiff.DiffIndex
  priv old_size : Int64
  priv old_hash : String
}

///|
/// Build the suffix index and hash the same old bytes once after it succeeds.
pub fn BundleIndex::build(
  old : Bytes,
  limits : @moonbsdiff.Limits,
) -> Result[BundleIndex, @moonbsdiff.BsdiffError] {
  @moonbsdiff.DiffIndex::build(old, limits).map(index => {
    index,
    old_size: old.length().to_int64(),
    old_hash: @manifest_support.sha256_hex(old),
  })
}

///|
/// Generate a bundle for one target with default generation options.
pub fn BundleIndex::diff(
  self : BundleIndex,
  new : Bytes,
  limits : @moonbsdiff.Limits,
) -> Result[PatchBundle, @moonbsdiff.BsdiffError] {
  self.diff_with_options(new, limits, @moonbsdiff.DiffOptions::default())
}

///|
/// Reuse the old suffixes and identity with fresh per-target generation limits.
pub fn BundleIndex::diff_with_options(
  self : BundleIndex,
  new : Bytes,
  limits : @moonbsdiff.Limits,
  options : @moonbsdiff.DiffOptions,
) -> Result[PatchBundle, @moonbsdiff.BsdiffError] {
  self.index
  .diff_with_options(new, limits, options)
  .map(patch => {
    patch,
    manifest: @manifest_support.make_manifest_with_old_identity(
      self.old_size,
      self.old_hash,
      new,
      patch,
    ),
  })
}
