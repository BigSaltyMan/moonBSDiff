// Linear-time O(n) SA-IS (Suffix Array Induced Sorting) implementation.
// Output contract: returns `sa` of length `n + 1` where `sa[0] == n` (empty
// sentinel suffix) and `data[sa[i]:] < data[sa[i + 1]:]` strictly for all
// `0 <= i < n`.

///|
priv struct SortBudget {
  mut remaining : Int64
}

///|
fn sorting_budget(limit : Int64) -> Result[SortBudget, BsdiffError] {
  if limit < 0L {
    Err(sorting_error(InvalidConfiguration, "sort_remaining", limit, None))
  } else {
    Ok({ remaining: limit, })
  }
}

///|
fn sorting_error(
  kind : ErrorKind,
  field : String,
  value : Int64,
  limit : Int64?,
) -> BsdiffError {
  format_error(kind, Sorting, None, None, Some(field), Some(value), limit)
}

///|
fn suffix_sizes(
  n : Int64,
  max_entries : Int64,
) -> Result[(Int32, Int32), BsdiffError] {
  if max_entries <= 0L || max_entries > 2147483647L {
    return Err(
      sorting_error(
        InvalidConfiguration,
        "suffix_entries",
        max_entries,
        Some(2147483647L),
      ),
    )
  }
  if n < 0L || n > 2147483646L {
    return Err(
      sorting_error(IntegerOverflow, "suffix_length", n, Some(2147483646L)),
    )
  }
  let entries = n + 1L
  if entries > max_entries {
    return Err(
      sorting_error(
        ResourceLimitExceeded,
        "suffix_entries",
        entries,
        Some(max_entries),
      ),
    )
  }
  Ok((entries.to_int(), if entries < 257L { 257 } else { entries.to_int() }))
}

///|
fn SortBudget::reserve(
  self : SortBudget,
  amount : Int64,
) -> Result[Unit, BsdiffError] {
  if amount < 0L {
    return Err(
      sorting_error(InvalidConfiguration, "sort_reservation", amount, Some(0L)),
    )
  }
  if self.remaining < 0L {
    return Err(
      sorting_error(
        InvalidConfiguration,
        "sort_remaining",
        self.remaining,
        None,
      ),
    )
  }
  if amount > self.remaining {
    return Err(
      sorting_error(
        ResourceLimitExceeded,
        "sort_remaining",
        amount,
        Some(self.remaining),
      ),
    )
  }
  self.remaining = self.remaining - amount
  Ok(())
}

///|
fn is_lms(is_s : Array[Bool], pos : Int32) -> Bool {
  pos > 0 && is_s[pos] && !is_s[pos - 1]
}

///|
fn lms_substrings_equal(
  s : Array[Int32],
  is_s : Array[Bool],
  m : Int32,
  a : Int32,
  b : Int32,
) -> Bool {
  if a == m - 1 || b == m - 1 {
    return a == b
  }
  let mut d = 0
  while true {
    let ia = a + d
    let ib = b + d
    if s[ia] != s[ib] || is_s[ia] != is_s[ib] {
      return false
    }
    if d > 0 {
      let a_end = is_lms(is_s, ia)
      let b_end = is_lms(is_s, ib)
      if a_end || b_end {
        return a_end && b_end
      }
    }
    d = d + 1
  }
  false
}

///|
fn bucket_heads(bkt_size : Array[Int32], bkt : Array[Int32], k : Int32) -> Unit {
  let mut sum = 0
  for c in 0..<k {
    bkt[c] = sum
    sum = sum + bkt_size[c]
  }
}

///|
fn bucket_tails(bkt_size : Array[Int32], bkt : Array[Int32], k : Int32) -> Unit {
  let mut sum = 0
  for c in 0..<k {
    sum = sum + bkt_size[c]
    bkt[c] = sum - 1
  }
}

///|
fn induce_sort(
  s : Array[Int32],
  sa : Array[Int32],
  is_s : Array[Bool],
  bkt_size : Array[Int32],
  bkt : Array[Int32],
  m : Int32,
  k : Int32,
) -> Unit {
  // Induce L-type suffixes from left to right.
  bucket_heads(bkt_size, bkt, k)
  for i in 0..<m {
    let pos = sa[i]
    if pos > 0 {
      let prev = pos - 1
      if !is_s[prev] {
        let sym = s[prev]
        let slot = bkt[sym]
        sa[slot] = prev
        bkt[sym] = slot + 1
      }
    }
  }
  // Induce S-type suffixes from right to left.
  bucket_tails(bkt_size, bkt, k)
  let mut i = m - 1
  while i >= 0 {
    let pos = sa[i]
    if pos > 0 {
      let prev = pos - 1
      if is_s[prev] {
        let sym = s[prev]
        let slot = bkt[sym]
        sa[slot] = prev
        bkt[sym] = slot - 1
      }
    }
    i = i - 1
  }
}

///|
// Recursive SA-IS core. Precondition: `m >= 2`, `k >= 2`, `s[m - 1] == 0` is
// the unique smallest sentinel, and `1 <= s[i] < k` for all `0 <= i < m - 1`.
fn sais_rec(
  s : Array[Int32],
  m : Int32,
  k : Int32,
  precomputed_bkt_size : Array[Int32]?,
  budget : SortBudget,
) -> Result[Array[Int32], BsdiffError] {
  let m64 = m.to_int64()
  let k64 = k.to_int64()
  let bkt_size = match precomputed_bkt_size {
    Some(existing) => existing
    None => {
      // Recursive level setup: allocate sa (m), is_s (m), bkt_size (k),
      // bkt (k), and count symbol frequencies into bkt_size (m).
      match budget.reserve(3L * m64 + 2L * k64) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      let counts = Array::make(k, 0)
      for i in 0..<m {
        let sym = s[i]
        counts[sym] = counts[sym] + 1
      }
      counts
    }
  }
  let sa = Array::make(m, -1)
  let is_s = Array::make(m, false)
  let bkt = Array::make(k, 0)
  // Classify S/L types (m) and collect LMS positions in text order (m).
  match budget.reserve(2L * m64) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  is_s[m - 1] = true
  is_s[m - 2] = false
  let mut idx = m - 3
  while idx >= 0 {
    let cur = s[idx]
    let nxt = s[idx + 1]
    is_s[idx] = if cur < nxt {
      true
    } else if cur > nxt {
      false
    } else {
      is_s[idx + 1]
    }
    idx = idx - 1
  }
  let lms_pos : Array[Int32] = []
  for pos in 1..<m {
    if is_s[pos] && !is_s[pos - 1] {
      lms_pos.push(pos)
    }
  }
  let lms_count = lms_pos.length()
  let lms_count64 = lms_count.to_int64()
  // First induced sort: place LMS at bucket tails (k + lms_count),
  // induce L (k + m), and induce S (k + m).
  match budget.reserve(2L * m64 + 3L * k64 + lms_count64) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  bucket_tails(bkt_size, bkt, k)
  for pos in lms_pos {
    let sym = s[pos]
    let slot = bkt[sym]
    sa[slot] = pos
    bkt[sym] = slot - 1
  }
  induce_sort(s, sa, is_s, bkt_size, bkt, m, k)
  if lms_count == 1 {
    return Ok(sa)
  }
  // Name LMS substrings in induced order: allocate lms_names (half), scan sa
  // (m), and compare adjacent LMS substrings (at most m + lms_count visits).
  let half = (m - 1) / 2 + 1
  match budget.reserve(2L * m64 + lms_count64 + half.to_int64()) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let lms_names = Array::make(half, -1)
  lms_names[(m - 1) / 2] = 0
  let mut prev_lms = m - 1
  let mut name = 0
  for i in 1..<m {
    let pos = sa[i]
    if is_lms(is_s, pos) {
      if !lms_substrings_equal(s, is_s, m, prev_lms, pos) {
        name = name + 1
      }
      lms_names[pos / 2] = name
      prev_lms = pos
    }
  }
  let k1 = name + 1
  // Order LMS suffixes: directly extract if all names are distinct, else recurse.
  let sorted_lms = if k1 == lms_count {
    match budget.reserve(m64 + lms_count64) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    let ordered = Array::make(lms_count, 0)
    let mut out = 0
    for i in 0..<m {
      let pos = sa[i]
      if is_lms(is_s, pos) {
        ordered[out] = pos
        out = out + 1
      }
    }
    ordered
  } else {
    match budget.reserve(2L * lms_count64) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    let s1 = Array::makei(lms_count, j => lms_names[lms_pos[j] / 2])
    let sa1 = match sais_rec(s1, lms_count, k1, None, budget) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    match budget.reserve(2L * lms_count64) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    Array::makei(lms_count, j => lms_pos[sa1[j]])
  }
  // Final induced sort: reset sa (m), scatter sorted LMS right-to-left
  // (k + lms_count), induce L (k + m), and induce S (k + m).
  match budget.reserve(3L * m64 + 3L * k64 + lms_count64) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  for i in 0..<m {
    sa[i] = -1
  }
  bucket_tails(bkt_size, bkt, k)
  let mut j = lms_count - 1
  while j >= 0 {
    let pos = sorted_lms[j]
    let sym = s[pos]
    let slot = bkt[sym]
    sa[slot] = pos
    bkt[sym] = slot - 1
    j = j - 1
  }
  induce_sort(s, sa, is_s, bkt_size, bkt, m, k)
  Ok(sa)
}

///|
// Internal index construction; generation supplies explicit entry/work limits.
fn build_suffix_array_view(
  data : BytesView,
  max_entries : Int64,
  budget : SortBudget,
) -> Result[Array[Int32], BsdiffError] {
  let (size, buckets) = match
    suffix_sizes(data.length().to_int64(), max_entries) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  // Initialization visits: top-level N-element arrays and byte bucket tables.
  let initial = if size == 1 {
    1L
  } else {
    4L * size.to_int64() + buckets.to_int64()
  }
  match budget.reserve(initial) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let n = size - 1
  if n == 0 {
    return Ok([0])
  }
  // Alphabet compaction + frequency counting + symbol mapping / unique fast-path:
  // count `data` (n), compact 256 byte slots (256), and either scatter `sa` or
  // populate dense `s` (size).
  match budget.reserve(2L * size.to_int64() + 256L) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let raw_counts = Array::make(256, 0)
  for i in 0..<n {
    let byte_val = data[i].to_int()
    raw_counts[byte_val] = raw_counts[byte_val] + 1
  }
  let remap = Array::make(256, 0)
  let bkt_size : Array[Int32] = [1]
  let mut sigma = 0
  for byte_val in 0..<256 {
    let count = raw_counts[byte_val]
    if count > 0 {
      sigma = sigma + 1
      remap[byte_val] = sigma
      bkt_size.push(count)
    }
  }
  if sigma == n {
    let sa = Array::make(size, 0)
    sa[0] = n
    for i in 0..<n {
      sa[remap[data[i].to_int()]] = i
    }
    return Ok(sa)
  }
  let s = Array::make(size, 0)
  for i in 0..<n {
    s[i] = remap[data[i].to_int()]
  }
  s[n] = 0
  sais_rec(s, size, sigma + 1, Some(bkt_size), budget)
}

///|
fn build_suffix_array(
  data : Bytes,
  max_entries : Int64,
  budget : SortBudget,
) -> Result[Array[Int32], BsdiffError] {
  build_suffix_array_view(data[:], max_entries, budget)
}
