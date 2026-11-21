// Original prefix-doubling/counting-sort implementation. qsufsort result contract
// is the reference; see docs/suffix-array.md for the deliberate algorithm change.

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
fn suffix_first_pass(
  source : Array[Int32],
  dest : Array[Int32],
  rank : Array[Int32],
  counts : Array[Int32],
  keys : Int32,
) -> Unit {
  for key in 0..<keys {
    counts[key] = 0
  }
  for pos in source {
    let key = rank[pos]
    counts[key] = counts[key] + 1
  }
  let mut total = 0
  for key in 0..<keys {
    let count = counts[key]
    counts[key] = total
    total = total + count
  }
  for pos in source {
    let key = rank[pos]
    let slot = counts[key]
    dest[slot] = pos
    counts[key] = slot + 1
  }
}

///|
// Internal index construction; generation supplies explicit entry/work limits.
fn build_suffix_array(
  data : Bytes,
  max_entries : Int64,
  budget : SortBudget,
) -> Result[Array[Int32], BsdiffError] {
  let (size, buckets) = match
    suffix_sizes(data.length().to_int64(), max_entries) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  // Initialization visits: four N-element arrays and the count buckets.
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
  let sa = Array::make(size, 0)
  let scratch = Array::make(size, 0)
  let mut rank = Array::makei(size, i => {
    if i == n {
      0
    } else {
      data[i].to_int() + 1
    }
  })
  let mut next = Array::make(size, 0)
  let counts = Array::make(buckets, 0)
  // Initial length-1 counting sort + dense reranking:
  // `counts` is already zeroed from allocation, so count (N) + prefix sum (257)
  // + scatter (N) + dense reranking (N) costs 3N + 257 visits.
  // Post-condition (base invariant for step = 1): `sa` is sorted by 1-byte
  // prefixes and `rank` holds dense equivalence classes in 0..<keys with
  // `rank[n] == 0` unique (`sa[0] == n`). If all suffixes are already distinct
  // (`classes == size`), return immediately without doubling.
  match budget.reserve(3L * size.to_int64() + 257L) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  for pos in 0..<size {
    let key = rank[pos]
    counts[key] = counts[key] + 1
  }
  let mut total = 0
  for key in 0..<257 {
    let count = counts[key]
    counts[key] = total
    total = total + count
  }
  for pos in 0..<size {
    let key = rank[pos]
    let slot = counts[key]
    sa[slot] = pos
    counts[key] = slot + 1
  }
  let mut prev_init_rank = rank[sa[0]]
  next[sa[0]] = 0
  let mut init_classes = 1
  for i in 1..<size {
    let b = sa[i]
    let rb = rank[b]
    if prev_init_rank != rb {
      init_classes = init_classes + 1
      prev_init_rank = rb
    }
    next[b] = init_classes - 1
  }
  if init_classes == size {
    return Ok(sa)
  }
  let old_rank = rank
  rank = next
  next = old_rank
  let mut keys = init_classes
  let mut step = 1
  // Doubling invariant: before each round, `sa` is sorted by `step`-byte
  // prefixes and `rank` holds their dense classes in 0..<keys. Ordering the
  // second key linearly (sentinels `pos > n - step` first, then `sa[i] - step`
  // in ascending `sa` order) followed by one stable counting sort on `rank`
  // produces the exact `2 * step`-byte prefix order.
  while step < size {
    // Linear second-key placement costs `step + N` loop visits, single stable
    // first-key counting pass costs `2N + 2K`, and dense reranking costs `N`.
    match
      budget.reserve(
        4L * size.to_int64() + step.to_int64() + 2L * keys.to_int64(),
      ) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    let mut out = 0
    for pos in (size - step)..<size {
      scratch[out] = pos
      out = out + 1
    }
    for i in 0..<size {
      let pos = sa[i]
      if pos >= step {
        scratch[out] = pos - step
        out = out + 1
      }
    }
    suffix_first_pass(scratch, sa, rank, counts, keys)
    let mut a = sa[0]
    let mut ra = rank[a]
    next[a] = 0
    let mut classes = 1
    for i in 1..<size {
      let b = sa[i]
      let rb = rank[b]
      let diff = if ra != rb {
        true
      } else {
        let sa2 = if step <= n - a { rank[a + step] } else { 0 }
        let sb2 = if step <= n - b { rank[b + step] } else { 0 }
        sa2 != sb2
      }
      if diff {
        classes = classes + 1
      }
      next[b] = classes - 1
      a = b
      ra = rb
    }
    if classes == size {
      return Ok(sa)
    }
    // A full-length prefix must distinguish every suffix. Check before doubling.
    if step >= size - step {
      return Err(
        sorting_error(
          InvalidField,
          "suffix_progress",
          step.to_int64(),
          Some(size.to_int64()),
        ),
      )
    }
    let old = rank
    rank = next
    next = old
    keys = classes
    step = step + step
  }
  Err(
    sorting_error(
      InvalidField,
      "suffix_progress",
      step.to_int64(),
      Some(size.to_int64()),
    ),
  )
}
