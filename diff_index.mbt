///|
/// Reusable old bytes and suffix positions. Safe Bytes APIs are immutable;
/// neither the suffix array nor mutable budgets are exposed or cached publicly.
pub struct DiffIndex {
  priv old_bytes : Bytes
  priv suffixes : Array[Int32]
}

///|
/// Validate old size and build once with one cumulative sorting quota.
/// Other Limits fields must be valid, but no target/output is generated here.
pub fn DiffIndex::build(
  old_bytes : Bytes,
  limits : Limits,
) -> Result[DiffIndex, BsdiffError] {
  match limits.validate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let size = old_bytes.length().to_int64()
  if size > limits.max_old_bytes {
    return Err(
      generation_error(
        ResourceLimitExceeded,
        Header,
        "max_old_bytes",
        size,
        Some(limits.max_old_bytes),
      ),
    )
  }
  let budget = match sorting_budget(limits.max_sort_work) {
    Err(e) => return Err(e)
    Ok(b) => b
  }
  // The builder checks n+1, buckets and all reservations before allocation.
  let suffixes = match build_suffix_array(old_bytes, 2147483647L, budget) {
    Err(e) => return Err(e)
    Ok(sa) => sa
  }
  // Only the immutable Bytes reference and final SA survive construction.
  Ok({ old_bytes, suffixes, })
}

///|
/// Generate with fresh per-target quotas; no sorting occurs or is charged.
/// Revalidate all limits, including bound old size, on every call.
pub fn DiffIndex::diff(
  self : DiffIndex,
  new_bytes : Bytes,
  limits : Limits,
) -> Result[Bytes, BsdiffError] {
  match generation_preflight(self.old_bytes, new_bytes, limits) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let work = match matching_budget(limits.max_match_work) {
    Err(e) => return Err(e)
    Ok(b) => b
  }
  generate_indexed_patch(self.old_bytes, new_bytes, self.suffixes, limits, work)
}
