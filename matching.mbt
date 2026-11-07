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
fn MatchBudget::tick(self : MatchBudget) -> Unit raise MatchingFault {
  if self.remaining < 0L {
    raise Stop(
      matching_error(
        InvalidConfiguration,
        "match_remaining",
        Some(self.remaining),
        None,
      ),
    )
  }
  if self.remaining == 0L {
    raise Stop(
      matching_error(
        ResourceLimitExceeded,
        "match_remaining",
        Some(1L),
        Some(0L),
      ),
    )
  }
  self.remaining = self.remaining - 1L
}

///|
fn match_position(old : Bytes, pos : Int32) -> Unit raise MatchingFault {
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
fn match_shape(
  old : Bytes,
  new : Bytes,
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
fn prefix_order(
  old : Bytes,
  pos : Int32,
  new : Bytes,
  at : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  match_position(old, pos)
  let mut i = 0
  let cap = if old.length() - pos < new.length() - at {
    old.length() - pos
  } else {
    new.length() - at
  }
  while i < cap {
    budget.tick()
    if old[pos + i] != new[at + i] {
      return if old[pos + i].to_int() < new[at + i].to_int() { -1 } else { 1 }
    }
    i = i + 1
  }
  if old.length() - pos < new.length() - at {
    -1
  } else if old.length() - pos > new.length() - at {
    1
  } else {
    0
  }
}

///|
fn prefix_length(
  old : Bytes,
  pos : Int32,
  new : Bytes,
  at : Int32,
  budget : MatchBudget,
) -> Int32 raise MatchingFault {
  match_position(old, pos)
  let mut i = 0
  while i < old.length() - pos && i < new.length() - at {
    budget.tick()
    if old[pos + i] != new[at + i] {
      break
    }
    i = i + 1
  }
  i
}

///|
fn search_match(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  at : Int32,
  budget : MatchBudget,
) -> (Int32, Int32) raise MatchingFault {
  match_shape(old, new, sa, at)
  let mut lo = 0
  let mut hi = sa.length()
  while lo < hi {
    budget.tick()
    let mid = lo + (hi - lo) / 2
    if prefix_order(old, sa[mid], new, at, budget) < 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let mut pos = old.length()
  let mut length = 0
  if lo > 0 {
    pos = sa[lo - 1]
    length = prefix_length(old, pos, new, at, budget)
  }
  if lo < sa.length() {
    let right = prefix_length(old, sa[lo], new, at, budget)
    if right >= length {
      pos = sa[lo]
      length = right
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
  Ok(search_match(old, new, sa, at, budget)) catch {
    Stop(e) => Err(e)
  }
}

///|
fn aligned_equal(
  old : Bytes,
  new : Bytes,
  at : Int32,
  offset : Int64,
  budget : MatchBudget,
) -> Bool raise MatchingFault {
  budget.tick()
  let pos = at.to_int64() + offset
  pos >= 0L && pos < old.length().to_int64() && old[pos.to_int()] == new[at]
}

///|
fn forward_choice(
  old : Bytes,
  new : Bytes,
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
fn backward_choice(
  old : Bytes,
  new : Bytes,
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
fn overlap_cut(
  old : Bytes,
  new : Bytes,
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
