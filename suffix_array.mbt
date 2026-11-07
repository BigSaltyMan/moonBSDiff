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
fn suffix_second(
  rank : Array[Int32],
  pos : Int32,
  step : Int32,
  n : Int32,
) -> Int32 {
  if step <= n - pos {
    rank[pos + step]
  } else {
    0
  }
}

///|
fn suffix_radix_pass(
  source : Array[Int32],
  dest : Array[Int32],
  rank : Array[Int32],
  counts : Array[Int32],
  keys : Int32,
  step : Int32,
  n : Int32,
  second : Bool,
) -> Unit {
  for key in 0..<keys {
    counts[key] = 0
  }
  for pos in source {
    let key = if second { suffix_second(rank, pos, step, n) } else { rank[pos] }
    counts[key] = counts[key] + 1
  }
  let mut total = 0
  for key in 0..<keys {
    let count = counts[key]
    counts[key] = total
    total = total + count
  }
  for pos in source {
    let key = if second { suffix_second(rank, pos, step, n) } else { rank[pos] }
    dest[counts[key]] = pos
    counts[key] = counts[key] + 1
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
  let sa = Array::makei(size, i => i)
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
  let mut keys = 257
  let mut step = 1
  while step < size {
    // Two stable passes cost 4N + 4K visits; dense reranking costs N.
    match budget.reserve(5L * size.to_int64() + 4L * keys.to_int64()) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    suffix_radix_pass(sa, scratch, rank, counts, keys, step, n, true)
    suffix_radix_pass(scratch, sa, rank, counts, keys, step, n, false)
    next[sa[0]] = 0
    let mut classes = 1
    for i in 1..<size {
      let a = sa[i - 1]
      let b = sa[i]
      if rank[a] != rank[b] ||
        suffix_second(rank, a, step, n) != suffix_second(rank, b, step, n) {
        classes = classes + 1
      }
      next[b] = classes - 1
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
