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
// A future encoder consumes these ranges; no payload bytes are produced here.
#warnings("-unused_field")
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
#warnings("-unused_value")
fn select_segments(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  max_segments : Int64,
  budget : MatchBudget,
) -> Result[Array[DiffSegment], BsdiffError] {
  Ok(scan_segments(old, new, sa, max_segments, budget)) catch {
    Stop(e) => Err(e)
  }
}
