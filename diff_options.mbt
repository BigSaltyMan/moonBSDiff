///|
/// Generation preferences, independent of resource Limits. Only bzip2 level is
/// configurable; the default is 9 and all three streams use the same level.
pub(all) struct DiffOptions {
  compression_level : Int32
}

///|
pub fn DiffOptions::default() -> DiffOptions {
  { compression_level: 9, }
}

///|
/// Reject before sorting or encoding; the dependency's clamping is not policy.
pub fn DiffOptions::validate(self : DiffOptions) -> Result[Unit, BsdiffError] {
  if self.compression_level < 1 || self.compression_level > 9 {
    Err(
      generation_error(
        InvalidConfiguration,
        Configuration,
        "compression_level",
        self.compression_level.to_int64(),
        Some(9L),
      ),
    )
  } else {
    Ok(())
  }
}
