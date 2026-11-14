// Copyright 2003-2005 Colin Percival
// All rights reserved
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted providing that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
// OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
// IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

///|
// Ranges selected by the scan and consumed by the block encoder.
priv struct DiffSegment {
  new_start : Int32
  old_start : Int32
  diff_length : Int32
  extra_length : Int32
  seek : Int64
}

///|
fn scan_segments(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  max_segments : Int64,
  budget : MatchBudget,
  raw_limit : Int64,
) -> Array[DiffSegment] raise MatchingFault {
  match_shape(old, new, sa, 0)
  if max_segments < 0L || max_segments > 2147483647L {
    raise Stop(
      matching_error(
        InvalidConfiguration,
        "segments",
        Some(max_segments),
        Some(2147483647L),
      ),
    )
  }
  let segments : Array[DiffSegment] = []
  let mut scan = 0
  let mut length = 0
  let mut pos = 0
  let mut last_scan = 0
  let mut last_pos = 0
  let mut offset = 0L
  while scan < new.length() {
    budget.tick()
    let previous_scan = scan
    scan = scan + length
    let mut old_score = 0L
    let mut scored = scan
    while scan < new.length() {
      budget.tick()
      let (p, l) = search_match(old, new, sa, scan, budget)
      pos = p
      length = l
      while scored < scan + length {
        if aligned_equal(old, new, scored, offset, budget) {
          old_score = old_score + 1L
        }
        scored = scored + 1
      }
      if (length.to_int64() == old_score && length != 0) ||
        length.to_int64() > old_score + 8L {
        break
      }
      if aligned_equal(old, new, scan, offset, budget) {
        old_score = old_score - 1L
      }
      scan = scan + 1
    }
    if length.to_int64() != old_score || scan == new.length() {
      let mut front = forward_choice(
        old, new, last_pos, last_scan, scan, budget,
      )
      let mut back = if scan < new.length() {
        backward_choice(old, new, pos, scan, last_scan, budget)
      } else {
        0
      }
      if front > scan - last_scan - back {
        let overlap = front - (scan - last_scan - back)
        let cut = overlap_cut(
          old,
          new,
          last_pos + front - overlap,
          pos - back,
          last_scan + front - overlap,
          overlap,
          budget,
        )
        front = front - (overlap - cut)
        back = back - cut
      }
      if segments.length().to_int64() >= max_segments {
        raise Stop(
          matching_error(
            ResourceLimitExceeded,
            "segments",
            Some(segments.length().to_int64() + 1L),
            Some(max_segments),
          ),
        )
      }
      // Every complete plan has exactly new.length() payload bytes. Check the
      // next control triple before the segment array grows, not after scanning.
      match
        raw_control_size(
          segments.length().to_int64() + 1L,
          new.length().to_int64(),
          0L,
          raw_limit,
        ) {
        Ok(_) => ()
        Err(e) => raise Stop(e)
      }
      budget.tick()
      let target = pos - back
      segments.push({
        new_start: last_scan,
        old_start: last_pos,
        diff_length: front,
        extra_length: scan - back - (last_scan + front),
        seek: target.to_int64() - (last_pos.to_int64() + front.to_int64()),
      })
      last_scan = scan - back
      last_pos = target
      offset = pos.to_int64() - scan.to_int64()
    }
    if scan == previous_scan && length == 0 {
      raise Stop(
        matching_error(
          InvalidField,
          "scan_progress",
          Some(scan.to_int64()),
          None,
        ),
      )
    }
  }
  segments
}

///|
fn select_segments(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  max_segments : Int64,
  budget : MatchBudget,
  raw_limit~ : Int64 = 9223372036854775807L,
) -> Result[Array[DiffSegment], BsdiffError] {
  Ok(scan_segments(old, new, sa, max_segments, budget, raw_limit)) catch {
    Stop(e) => Err(e)
  }
}

///|
priv struct RawPatchBlocks {
  control : Bytes
  difference : Bytes
  extra : Bytes
}

///|
fn generation_error(
  kind : ErrorKind,
  stage : ErrorStage,
  field : String,
  value : Int64,
  limit : Int64?,
) -> BsdiffError {
  format_error(kind, stage, None, None, Some(field), Some(value), limit)
}

///|
fn raw_control_size(
  count : Int64,
  difference : Int64,
  extra : Int64,
  total_limit : Int64,
) -> Result[Int32, BsdiffError] {
  if count < 0L || count > 2147483647L / 24L {
    return Err(
      generation_error(
        IntegerOverflow,
        Control,
        "control_bytes",
        count,
        Some(2147483647L / 24L),
      ),
    )
  }
  for value in [difference, extra] {
    if value < 0L || value > 2147483647L {
      return Err(
        generation_error(
          IntegerOverflow,
          Output,
          "raw_block_bytes",
          value,
          Some(2147483647L),
        ),
      )
    }
  }
  let control = count * 24L
  let total = control + difference + extra
  if total > total_limit {
    return Err(
      generation_error(
        ResourceLimitExceeded,
        Control,
        "max_decompressed_bytes",
        total,
        Some(total_limit),
      ),
    )
  }
  Ok(control.to_int())
}

///|
fn encode_plan(
  old : Bytes,
  new : Bytes,
  plan : Array[DiffSegment],
  limits : Limits,
  budget : MatchBudget,
) -> Result[RawPatchBlocks, BsdiffError] {
  match budget.reserve(plan.length().to_int64()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let mut covered = 0
  let mut old_cursor = 0L
  let mut differences = 0L
  let mut extras = 0L
  for segment in plan {
    if segment.new_start != covered ||
      segment.old_start.to_int64() != old_cursor ||
      segment.old_start < 0 ||
      segment.old_start > old.length() ||
      segment.diff_length < 0 ||
      segment.extra_length < 0 {
      return Err(
        generation_error(
          InvalidField,
          Control,
          "segment_ranges",
          covered.to_int64(),
          None,
        ),
      )
    }
    if segment.diff_length > old.length() - segment.old_start ||
      segment.diff_length > new.length() - covered ||
      segment.extra_length > new.length() - covered - segment.diff_length {
      return Err(
        generation_error(
          InvalidField,
          Control,
          "segment_lengths",
          covered.to_int64(),
          None,
        ),
      )
    }
    let advanced = match
      cursor_add(
        old_cursor,
        segment.diff_length.to_int64(),
        "generation_old_plus_x",
      ) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    old_cursor = match
      cursor_add(advanced, segment.seek, "generation_old_plus_z") {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    if old_cursor < 0L || old_cursor > old.length().to_int64() {
      return Err(
        generation_error(
          InvalidField,
          Control,
          "segment_old_cursor",
          old_cursor,
          Some(old.length().to_int64()),
        ),
      )
    }
    covered = covered + segment.diff_length + segment.extra_length
    differences = differences + segment.diff_length.to_int64()
    extras = extras + segment.extra_length.to_int64()
  }
  if covered != new.length() {
    return Err(
      generation_error(
        InvalidField,
        Control,
        "segment_coverage",
        covered.to_int64(),
        Some(new.length().to_int64()),
      ),
    )
  }
  if plan.length().to_int64() > limits.max_control_instructions {
    return Err(
      generation_error(
        ResourceLimitExceeded,
        Control,
        "max_control_instructions",
        plan.length().to_int64(),
        Some(limits.max_control_instructions),
      ),
    )
  }
  let control_size = match
    raw_control_size(
      plan.length().to_int64(),
      differences,
      extras,
      limits.max_decompressed_bytes,
    ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  // Four byte-visits per raw byte cover zeroing, encoding, conversion/copies
  // and the small integer-encoding temporaries. Plus one visit per segment.
  let raw_bytes = control_size.to_int64() + differences + extras
  match budget.reserve(4L * raw_bytes + plan.length().to_int64()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let control = Array::make(control_size, b'\x00')
  let mut control_pos = 0
  let difference = Array::make(differences.to_int(), b'\x00')
  let extra = Array::make(extras.to_int(), b'\x00')
  let mut diff_pos = 0
  let mut extra_pos = 0
  for segment in plan {
    for
      value in [
        segment.diff_length.to_int64(),
        segment.extra_length.to_int64(),
        segment.seek,
      ] {
      let encoded = match encode_int(value) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      for byte in encoded {
        control[control_pos] = byte
        control_pos = control_pos + 1
      }
    }
    for i in 0..<segment.diff_length {
      difference[diff_pos + i] = ((
        new[segment.new_start + i].to_int() -
        old[segment.old_start + i].to_int() +
        256
      ) %
      256).to_byte()
    }
    diff_pos = diff_pos + segment.diff_length
    for i in 0..<segment.extra_length {
      extra[extra_pos + i] = new[segment.new_start + segment.diff_length + i]
    }
    extra_pos = extra_pos + segment.extra_length
  }
  if control_pos != control_size ||
    diff_pos.to_int64() != differences ||
    extra_pos.to_int64() != extras {
    return Err(
      generation_error(
        InvalidField,
        Control,
        "encoded_plan_lengths",
        control.length().to_int64(),
        Some(control_size.to_int64()),
      ),
    )
  }
  Ok({
    control: Bytes::from_array(control),
    difference: Bytes::from_array(difference),
    extra: Bytes::from_array(extra),
  })
}

///|
fn generated_patch_size(
  control : Int64,
  difference : Int64,
  extra : Int64,
  cap : Int64,
) -> Result[Int32, BsdiffError] {
  let mut total = 32L
  for length in [control, difference, extra] {
    if length < 0L || length > 2147483647L - total {
      return Err(
        generation_error(
          IntegerOverflow,
          Header,
          "patch_bytes",
          length,
          Some(2147483647L - total),
        ),
      )
    }
    total = total + length
  }
  if total > cap {
    return Err(
      generation_error(
        ResourceLimitExceeded,
        Header,
        "max_patch_bytes",
        total,
        Some(cap),
      ),
    )
  }
  Ok(total.to_int())
}

///|
// Shared by one-shot and reusable-index generation; check before sorting or
// entering the per-target scan/encoding pipeline.
fn generation_preflight(
  old_bytes : Bytes,
  new_bytes : Bytes,
  limits : Limits,
) -> Result[Unit, BsdiffError] {
  match limits.validate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  for
    (field, value, cap) in [
      ("max_old_bytes", old_bytes.length().to_int64(), limits.max_old_bytes),
      ("max_new_bytes", new_bytes.length().to_int64(), limits.max_new_bytes),
      (
        "max_output_bytes",
        new_bytes.length().to_int64(),
        limits.max_output_bytes,
      ),
      ("max_patch_bytes", 74L, limits.max_patch_bytes),
    ] {
    if value > cap {
      return Err(
        generation_error(ResourceLimitExceeded, Header, field, value, Some(cap)),
      )
    }
  }

  // Even before indexing, the full payload and (for nonempty targets) at
  // least one control triple are unavoidable. Exact plan growth is checked
  // separately before every push.
  match
    raw_control_size(
      if new_bytes.length() == 0 {
        0L
      } else {
        1L
      },
      new_bytes.length().to_int64(),
      0L,
      limits.max_decompressed_bytes,
    ) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  Ok(())
}

///|
/// Generate a standard BSDIFF40 patch with explicit generation limits.
fn generate_patch(
  old_bytes : Bytes,
  new_bytes : Bytes,
  limits : Limits,
  sort_budget : SortBudget,
  match_budget : MatchBudget,
) -> Result[Bytes, BsdiffError] {
  match generation_preflight(old_bytes, new_bytes, limits) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let sa = match build_suffix_array(old_bytes, 2147483647L, sort_budget) {
    Err(e) => return Err(e)
    Ok(v) => v
  }

  generate_indexed_patch(old_bytes, new_bytes, sa, limits, match_budget)
}

///|
// Both callers have passed generation_preflight. This function only reads sa;
// it owns no persistent work state and never constructs/sorts an index.
fn generate_indexed_patch(
  old_bytes : Bytes,
  new_bytes : Bytes,
  sa : Array[Int32],
  limits : Limits,
  match_budget : MatchBudget,
) -> Result[Bytes, BsdiffError] {
  let segment_cap = if limits.max_control_instructions < 2147483647L / 24L {
    limits.max_control_instructions
  } else {
    2147483647L / 24L
  }
  let plan = match
    select_segments(
      old_bytes,
      new_bytes,
      sa,
      segment_cap,
      match_budget,
      raw_limit=limits.max_decompressed_bytes,
    ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let raw = match
    encode_plan(old_bytes, new_bytes, plan, limits, match_budget) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let compressed_budget = PatchBudget::{
    used: 32L,
    limit: limits.max_patch_bytes,
  }
  let control = match
    compress_generation_block(raw.control, compressed_budget, match_budget) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let difference = match
    compress_generation_block(raw.difference, compressed_budget, match_budget) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let extra = match
    compress_generation_block(raw.extra, compressed_budget, match_budget) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let size = match
    generated_patch_size(
      control.length().to_int64(),
      difference.length().to_int64(),
      extra.length().to_int64(),
      limits.max_patch_bytes,
    ) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let control_len = match encode_int(control.length().to_int64()) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let diff_len = match encode_int(difference.length().to_int64()) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let new_len = match encode_int(new_bytes.length().to_int64()) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  // The final array, write pass and immutable result copy share the same quota.
  match match_budget.reserve(3L * size.to_int64()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let patch = Array::make(size, b'\x00')
  let mut at = 0
  for
    bytes in [
      b"BSDIFF40", control_len, diff_len, new_len, control, difference, extra,
    ] {
    for byte in bytes {
      patch[at] = byte
      at = at + 1
    }
  }
  Ok(Bytes::from_array(patch))
}

///|
/// Generate a standard BSDIFF40 patch; every invocation owns fresh budgets.
pub fn diff(
  old_bytes : Bytes,
  new_bytes : Bytes,
  limits : Limits,
) -> Result[Bytes, BsdiffError] {
  match limits.validate() {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let sort = match sorting_budget(limits.max_sort_work) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let work = match matching_budget(limits.max_match_work) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  generate_patch(old_bytes, new_bytes, limits, sort, work)
}
