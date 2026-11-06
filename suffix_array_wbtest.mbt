///|
fn suffix_test_budget(amount : Int64) -> SortBudget {
  match sorting_budget(amount) {
    Ok(b) => b
    Err(_) => abort("test budget rejected")
  }
}

///|
// Independent test-only comparison: original bytes and explicit lengths only.
fn naive_suffix_less(data : Bytes, left : Int32, right : Int32) -> Bool {
  let mut a = left
  let mut b = right
  while a < data.length() && b < data.length() {
    if data[a] != data[b] {
      return data[a].to_int() < data[b].to_int()
    }
    a = a + 1
    b = b + 1
  }
  a == data.length() && b != data.length()
}

///|
fn naive_suffix_array(data : Bytes) -> Array[Int32] {
  let positions = Array::makei(data.length() + 1, i => i)
  for i in 1..<positions.length() {
    let value = positions[i]
    let mut j = i
    while j > 0 && naive_suffix_less(data, value, positions[j - 1]) {
      positions[j] = positions[j - 1]
      j = j - 1
    }
    positions[j] = value
  }
  positions
}

///|
fn suffix_test_build(data : Bytes) -> Array[Int32] {
  match build_suffix_array(data, 100000L, suffix_test_budget(1000000000L)) {
    Ok(sa) => sa
    Err(_) => abort("suffix construction failed")
  }
}

///|
fn suffix_test_complete(data : Bytes, sa : Array[Int32]) -> Unit {
  try! assert_eq(sa.length(), data.length() + 1)
  let seen = Array::make(data.length() + 1, false)
  for pos in sa {
    try! assert_true(pos >= 0 && pos <= data.length())
    try! assert_false(seen[pos])
    seen[pos] = true
  }
  for present in seen {
    try! assert_true(present)
  }
  try! assert_eq(sa[0], data.length())
  for i in 1..<sa.length() {
    try! assert_true(naive_suffix_less(data, sa[i - 1], sa[i]))
  }
}

///|
fn suffix_test_small(data : Bytes) -> Unit {
  let snapshot = data.to_array()
  let sa = suffix_test_build(data)
  suffix_test_complete(data, sa)
  try! assert_eq(sa, naive_suffix_array(data))
  try! assert_eq(data.to_array(), snapshot)
}

///|
fn suffix_test_random(length : Int32, seed : UInt32) -> Bytes {
  let mut state = seed
  let bytes : Array[Byte] = []
  for _ in 0..<length {
    state = state * 1664525U + 1013904223U
    bytes.push((state >> 24).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
test "suffix-compact-manual-complete-vectors" {
  for
    (data, expected) in [
      (b"", [0]),
      (b"\xff", [1, 0]),
      (b"banana", [6, 5, 3, 1, 0, 4, 2]),
      (b"\x00\xff\x00", [3, 2, 0, 1]),
      (b"AAAA", [4, 3, 2, 1, 0]),
      (b"aba", [3, 2, 0, 1]),
    ] {
    assert_eq(naive_suffix_array(data), expected)
    assert_eq(suffix_test_build(data), expected)
    suffix_test_small(data)
  }
}

///|
test "suffix-compact-binary-and-prefixes" {
  for
    data in [
      Bytes::from_array(Array::makei(256, i => i.to_byte())),
      Bytes::from_array(Array::makei(256, i => (255 - i).to_byte())),
      Bytes::from_array(Array::make(128, b'\x00')),
      Bytes::from_array(
        Array::makei(128, i => if i % 3 == 0 { b'\xff' } else { b'\x00' }),
      ),
      b"aaaaaaaaaaaaaaaabaaaaaaaaaaaaaaaac",
    ] {
    suffix_test_small(data)
  }
}

///|
test "suffix-compact-seeded-random" {
  for i in 0..<64 {
    suffix_test_small(
      suffix_test_random(i, 20261106U + i.reinterpret_as_uint()),
    )
  }
}

///|
test "suffix-compact-preflight-and-work-budget" {
  assert_eq(suffix_sizes(0L, 1L), Ok((1, 257)))
  assert_eq(
    suffix_sizes(2147483646L, 2147483647L),
    Ok((2147483647, 2147483647)),
  )
  for
    (n, max_entries, kind, field) in [
      (-1L, 1L, IntegerOverflow, "suffix_length"),
      (2147483647L, 2147483647L, IntegerOverflow, "suffix_length"),
      (9223372036854775807L, 2147483647L, IntegerOverflow, "suffix_length"),
      (1L, 1L, ResourceLimitExceeded, "suffix_entries"),
      (0L, 0L, InvalidConfiguration, "suffix_entries"),
      (0L, -1L, InvalidConfiguration, "suffix_entries"),
      (0L, 2147483648L, InvalidConfiguration, "suffix_entries"),
    ] {
    match suffix_sizes(n, max_entries) {
      Ok(_) => abort("bad size accepted")
      Err(e) => {
        assert_eq(e.kind, kind)
        assert_eq(e.stage, Sorting)
        assert_eq(e.field, Some(field))
        assert_eq(e.offset, None)
      }
    }
  }
  let preflight_budget = suffix_test_budget(17L)
  match build_suffix_array(b"A", 1L, preflight_budget) {
    Ok(_) => abort("entry limit bypassed")
    Err(e) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.limit, Some(1L))
    }
  }
  assert_eq(preflight_budget.remaining, 17L)
  let exact = suffix_test_budget(1040L)
  assert_eq(build_suffix_array(b"A", 2L, exact), Ok([1, 0]))
  assert_eq(exact.remaining, 0L)
  let short = suffix_test_budget(1039L)
  for budget in [exact, short, suffix_test_budget(0L)] {
    match build_suffix_array(b"A", 2L, budget) {
      Ok(_) => abort("work budget bypassed")
      Err(e) => {
        assert_eq(e.kind, ResourceLimitExceeded)
        assert_eq(e.stage, Sorting)
        assert_eq(e.field, Some("sort_remaining"))
      }
    }
  }
  assert_eq(short.remaining, 1037L)
  match sorting_budget(-1L) {
    Ok(_) => abort("negative budget accepted")
    Err(e) => assert_eq(e.kind, InvalidConfiguration)
  }
  assert_eq(build_suffix_array(b"A", 2L, suffix_test_budget(1040L)), Ok([1, 0]))
}

///|
test "suffix-compact-state-isolation" {
  let data = b"banana\x00\xff"
  let old = data.to_array()
  let first = suffix_test_build(data)
  let second = suffix_test_build(data)
  let expected = naive_suffix_array(data)
  assert_eq(first, expected)
  first[0] = 0
  assert_eq(second, expected)
  assert_eq(suffix_test_build(data), expected)
  assert_eq(data.to_array(), old)
}

///|
test "suffix-native-exhaustive" {
  let mut cases = 0
  let mut count = 1
  for length in 0..<8 {
    for code in 0..<count {
      let mut value = code
      let bytes : Array[Byte] = []
      for _ in 0..<length {
        bytes.push([b'\x00', b'\x01', b'\xff'][value % 3])
        value = value / 3
      }
      suffix_test_small(Bytes::from_array(bytes))
      cases = cases + 1
    }
    count = count * 3
  }
  assert_eq(cases, 3280)
}

///|
test "suffix-native-scale-and-growth" {
  for size in [1024, 4096, 16384] {
    let same = Bytes::from_array(Array::make(size, b'\xff'))
    let snapshot = same.to_array()
    let sa = suffix_test_build(same)
    assert_eq(sa, Array::makei(size + 1, i => size - i))
    assert_eq(same.to_array(), snapshot)
    let periodic = Bytes::from_array(Array::makei(size, i => (i % 7).to_byte()))
    let array = suffix_test_build(periodic)
    // For this period, suffixes sort by first byte, then shorter length.
    let expected : Array[Int32] = [size]
    for byte in 0..<7 {
      let mut pos = size - 1
      while pos >= 0 {
        if pos % 7 == byte {
          expected.push(pos)
        }
        pos = pos - 1
      }
    }
    assert_eq(array, expected)
    let random = suffix_test_random(size, 20261106U)
    let sorted = suffix_test_build(random)
    suffix_test_complete(random, sorted)
    assert_eq(suffix_test_build(random), sorted)
  }
}
