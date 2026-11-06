///|
/// Individual buffer byte limits are positive and at most 2147483647 (Int indices).
/// Total decompressed bytes are a positive Int64 aggregate.
/// Counts and work units are positive Int64 values. No zero means unlimited.
#derive(Eq, Debug)
pub(all) struct Limits {
  max_old_bytes : Int64
  max_new_bytes : Int64
  max_patch_bytes : Int64
  max_output_bytes : Int64
  max_decompressed_bytes : Int64
  max_control_instructions : Int64
  max_sort_work : Int64
  max_match_work : Int64
}

///|
/// Validate configuration only; runtime checks belong to the operation adapters.
pub fn Limits::validate(self : Limits) -> Result[Unit, BsdiffError] {
  let fields = [
    ("max_old_bytes", self.max_old_bytes, 2147483647L),
    ("max_new_bytes", self.max_new_bytes, 2147483647L),
    ("max_patch_bytes", self.max_patch_bytes, 2147483647L),
    ("max_output_bytes", self.max_output_bytes, 2147483647L),
    (
      "max_decompressed_bytes",
      self.max_decompressed_bytes,
      9223372036854775807L,
    ),
    (
      "max_control_instructions",
      self.max_control_instructions,
      9223372036854775807L,
    ),
    ("max_sort_work", self.max_sort_work, 9223372036854775807L),
    ("max_match_work", self.max_match_work, 9223372036854775807L),
  ]
  for (field, value, ceiling) in fields {
    if value <= 0L || value > ceiling {
      return Err({
        kind: InvalidConfiguration,
        stage: Configuration,
        block: None,
        offset: None,
        field: Some(field),
        value: Some(value),
        limit: Some(ceiling),
      })
    }
  }
  Ok(())
}

///|
pub extend Limits with Eq::{equal, not_equal}

///|
pub extend Limits with @debug.Debug::{to_repr}
