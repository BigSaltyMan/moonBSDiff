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
priv struct MatchBudget {
  mut remaining : Int64
}

///|
priv suberror MatchingFault {
  Stop(BsdiffError)
}

///|
fn matching_error(
  kind : ErrorKind,
  field : String,
  value : Int64?,
  limit : Int64?,
) -> BsdiffError {
  format_error(kind, Matching, None, None, Some(field), value, limit)
}

///|
fn matching_budget(limit : Int64) -> Result[MatchBudget, BsdiffError] {
  if limit < 0L {
    Err(
      matching_error(InvalidConfiguration, "match_remaining", Some(limit), None),
    )
  } else {
    Ok({ remaining: limit, })
  }
}

///|
fn MatchBudget::reserve(
  self : MatchBudget,
  amount : Int64,
) -> Result[Unit, BsdiffError] {
  if amount < 0L || self.remaining < 0L {
    return Err(
      matching_error(
        InvalidConfiguration,
        "match_reservation",
        Some(amount),
        Some(self.remaining),
      ),
    )
  }
  if amount > self.remaining {
    return Err(
      matching_error(
        ResourceLimitExceeded,
        "match_remaining",
        Some(amount),
        Some(self.remaining),
      ),
    )
  }
  self.remaining = self.remaining - amount
  Ok(())
}

///|
fn MatchBudget::tick(self : MatchBudget) -> Unit raise MatchingFault {
  if self.remaining > 0L {
    self.remaining = self.remaining - 1L
  } else {
    match self.reserve(1L) {
      Ok(_) => ()
      Err(e) => raise Stop(e)
    }
  }
}

///|
fn match_position_view(
  old : BytesView,
  pos : Int32,
) -> Unit raise MatchingFault {
  if pos < 0 || pos > old.length() {
    raise Stop(
      matching_error(
        InvalidField,
        "suffix_position",
        Some(pos.to_int64()),
        Some(old.length().to_int64()),
      ),
    )
  }
}

///|
fn match_shape_view(
  old : BytesView,
  new : BytesView,
  sa : Array[Int32],
  at : Int32,
) -> Unit raise MatchingFault {
  if sa.length().to_int64() != old.length().to_int64() + 1L {
    raise Stop(
      matching_error(
        InvalidField,
        "suffix_count",
        Some(sa.length().to_int64()),
        Some(old.length().to_int64() + 1L),
      ),
    )
  }
  if at < 0 || at > new.length() {
    raise Stop(
      matching_error(
        InvalidField,
        "new_position",
        Some(at.to_int64()),
        Some(new.length().to_int64()),
      ),
    )
  }
}

///|
fn search_match_view(
  old : BytesView,
  new : BytesView,
  sa : Array[Int32],
  at : Int32,
  budget : MatchBudget,
) -> (Int32, Int32) raise MatchingFault {
  match_shape_view(old, new, sa, at)
  let old_len = old.length()
  let new_rem = new.length() - at
  let sa_len = sa.length()
  let mut lo = 0
  let mut hi = sa_len
  // Invariant on sorted `sa`:
  // - Whenever `lo > 0`, `sa[lo - 1]` was the last `mid` strictly less than
  //   `new[at..]` and `lcp_lo` is its exact common prefix length with `new[at..]`.
  // - Whenever `hi < sa_len`, `sa[hi]` was the last `mid` >= `new[at..]`
  //   and `lcp_hi` is its exact common prefix length with `new[at..]`.
  // Because `sa[lo - 1] < sa[mid] < sa[hi]`, every suffix strictly between them
  // must share at least `min(lcp_lo, lcp_hi)` leading bytes with `new[at..]`.
  // Probing `sa_len - 1` on the first iteration establishes `lcp_hi` upfront
  // (and resolves queries greater than every suffix in one probe) instead of
  // leaving `lcp_hi == 0` along a long right-leaning branch.
  let mut lcp_lo = 0
  let mut lcp_hi = 0
  while lo < hi {
    budget.tick()
    let mid = if hi == sa_len && lo == 0 { hi - 1 } else { lo + (hi - lo) / 2 }
    let pos = sa[mid]
    match_position_view(old, pos)
    let old_rem = old_len - pos
    let cap = if old_rem < new_rem { old_rem } else { new_rem }
    let start = if lcp_lo < lcp_hi { lcp_lo } else { lcp_hi }
    let mut i = if start < cap { start } else { cap }
    let mut cmp = 0
    let mut decided = false
    while i < cap {
      budget.tick()
      let a = old[pos + i]
      let b = new[at + i]
      if a != b {
        cmp = if a.to_int() < b.to_int() { -1 } else { 1 }
        decided = true
        break
      }
      i = i + 1
    }
    if !decided {
      cmp = if old_rem < new_rem {
        -1
      } else if old_rem > new_rem {
        1
      } else {
        0
      }
    }
    if cmp < 0 {
      lo = mid + 1
      lcp_lo = i
    } else {
      hi = mid
      lcp_hi = i
    }
  }
  // At termination `lo == hi`: `sa[lo - 1]` (if `lo > 0`) and `sa[lo]` (if
  // `lo < sa_len`) were already validated and measured as the final left
  // and right bounds, so `lcp_lo` and `lcp_hi` give their exact match lengths.
  let mut pos = old_len
  let mut length = 0
  if lo > 0 {
    pos = sa[lo - 1]
    length = lcp_lo
  }
  if lo < sa_len {
    if lcp_hi >= length {
      pos = sa[lo]
      length = lcp_hi
    }
  }
  (pos, length)
}

///|
#warnings("-unused_value")
fn longest_match(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  at : Int32,
  budget : MatchBudget,
) -> Result[(Int32, Int32), BsdiffError] {
  Ok(search_match_view(old[:], new[:], sa, at, budget)) catch {
    Stop(e) => Err(e)
  }
}

///|
fn aligned_equal_view(
  old : BytesView,
  new : BytesView,
  at : Int32,
  offset : Int64,
  budget : MatchBudget,
) -> Bool raise MatchingFault {
  budget.tick()
  let pos = at.to_int64() + offset
  pos >= 0L && pos < old.length().to_int64() && old[pos.to_int()] == new[at]
}

///|
fn forward_choice_view(
  old : BytesView,
  new : BytesView,
  old_start : Int32,
  new_start : Int32,
  end : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  let mut i = 0
  let mut score = 0L
  let mut best = 0L
  let mut length = 0
  while i < end - new_start && i < old.length() - old_start {
    budget.tick()
    if old[old_start + i] == new[new_start + i] {
      score = score + 1L
    }
    i = i + 1
    if 2L * score - i.to_int64() > best {
      best = 2L * score - i.to_int64()
      length = i
    }
  }
  length
}

///|
#warnings("-unused_value")
fn forward_choice(
  old : Bytes,
  new : Bytes,
  old_start : Int32,
  new_start : Int32,
  end : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  forward_choice_view(old[:], new[:], old_start, new_start, end, budget)
}

///|
fn backward_choice_view(
  old : BytesView,
  new : BytesView,
  pos : Int32,
  scan : Int32,
  lower : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  let mut i = 0
  let mut score = 0L
  let mut best = 0L
  let mut length = 0
  while i < scan - lower && i < pos {
    budget.tick()
    i = i + 1
    if old[pos - i] == new[scan - i] {
      score = score + 1L
    }
    if 2L * score - i.to_int64() > best {
      best = 2L * score - i.to_int64()
      length = i
    }
  }
  length
}

///|
#warnings("-unused_value")
fn backward_choice(
  old : Bytes,
  new : Bytes,
  pos : Int32,
  scan : Int32,
  lower : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  backward_choice_view(old[:], new[:], pos, scan, lower, budget)
}

///|
fn overlap_cut_view(
  old : BytesView,
  new : BytesView,
  front_old : Int32,
  back_old : Int32,
  start : Int32,
  size : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  let mut score = 0L
  let mut best = 0L
  let mut cut = 0
  for i in 0..<size {
    budget.tick()
    if new[start + i] == old[front_old + i] {
      score = score + 1L
    }
    if new[start + i] == old[back_old + i] {
      score = score - 1L
    }
    if score > best {
      best = score
      cut = i + 1
    }
  }
  cut
}

///|
#warnings("-unused_value")
fn overlap_cut(
  old : Bytes,
  new : Bytes,
  front_old : Int32,
  back_old : Int32,
  start : Int32,
  size : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  overlap_cut_view(old[:], new[:], front_old, back_old, start, size, budget)
}
