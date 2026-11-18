///|
/// Restore in memory after checking the old bytes and patch against a trusted
/// schema 1 manifest. Return the recovered bytes only after verifying their identity.
pub fn apply(
  old : Bytes,
  patch : Bytes,
  manifest_bytes : Bytes,
  limits : @moonbsdiff.Limits,
) -> Result[Bytes, ManifestError] {
  match prepare(manifest_bytes, limits) {
    Ok(prepared) => prepared.restore(old, patch)
    Err(error) => Err(error)
  }
}
