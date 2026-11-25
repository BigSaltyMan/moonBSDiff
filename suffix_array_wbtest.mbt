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
  // N=2 (b"A"): pre-alloc 4N+257=265, alphabet compaction+scatter 2N+256=260 => 525.
  let exact = suffix_test_budget(525L)
  assert_eq(build_suffix_array(b"A", 2L, exact), Ok([1, 0]))
  assert_eq(exact.remaining, 0L)
  let short = suffix_test_budget(524L)
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
  assert_eq(short.remaining, 259L)
  // N=3 (b"AA"): pre-alloc 4*3+257=269, compaction 2*3+256=262,
  // classify+collect 2*3=6, first induce (k=2, lms=1) 2*3+3*2+1=13 => 550.
  let exact_aa = suffix_test_budget(550L)
  assert_eq(build_suffix_array(b"AA", 3L, exact_aa), Ok([2, 1, 0]))
  assert_eq(exact_aa.remaining, 0L)
  let short_aa = suffix_test_budget(549L)
  match build_suffix_array(b"AA", 3L, short_aa) {
    Ok(_) => abort("induced sort work budget bypassed")
    Err(e) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Sorting)
      assert_eq(e.field, Some("sort_remaining"))
      assert_eq(e.value, Some(13L))
      assert_eq(e.limit, Some(12L))
    }
  }
  assert_eq(short_aa.remaining, 12L)
  match sorting_budget(-1L) {
    Ok(_) => abort("negative budget accepted")
    Err(e) => assert_eq(e.kind, InvalidConfiguration)
  }
  assert_eq(build_suffix_array(b"A", 2L, suffix_test_budget(525L)), Ok([1, 0]))
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

///|
fn fibonacci_bytes(steps : Int32) -> Bytes {
  let mut a : Bytes = b"a"
  let mut b : Bytes = b"ab"
  if steps <= 0 {
    return a
  }
  for _ in 1..<steps {
    let next = b + a
    a = b
    b = next
  }
  b
}

///|
fn thue_morse_bytes(order : Int32) -> Bytes {
  let bytes : Array[Byte] = [b'\x00']
  for _ in 0..<order {
    let len = bytes.length()
    for i in 0..<len {
      bytes.push(if bytes[i] == b'\x00' { b'\xff' } else { b'\x00' })
    }
  }
  Bytes::from_array(bytes)
}

///|
fn repeat_bytes(unit : Bytes, times : Int32) -> Bytes {
  let out : Array[Byte] = []
  for _ in 0..<times {
    for b in unit {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
fn suffix_work_used(data : Bytes) -> (Array[Int32], Int64) {
  let cap = 100000000L
  let budget = suffix_test_budget(cap)
  match build_suffix_array(data, 1000000L, budget) {
    Ok(sa) => (sa, cap - budget.remaining)
    Err(_) => abort("suffix work measurement failed")
  }
}

///|
test "suffix-sais-edge-cases-and-views" {
  // All 256 single-byte values and all 2-byte boundary pairs.
  for b in 0..<256 {
    let single = Bytes::from_array([b.to_byte()])
    assert_eq(suffix_test_build(single), [1, 0])
  }
  for
    pair in [
      b"\x00\x00", b"\x00\xff", b"\xff\x00", b"\xff\xff", b"\x00\x01", b"\xfe\xff",
    ] {
    suffix_test_small(pair)
  }
  // Full 256-byte alphabet repeated forwards and backwards.
  let asc = Bytes::from_array(Array::makei(256, i => i.to_byte()))
  let desc = Bytes::from_array(Array::makei(256, i => (255 - i).to_byte()))
  let full_dup = asc + asc + desc
  let sa_full = suffix_test_build(full_dup)
  suffix_test_complete(full_dup, sa_full)
  // Non-zero offset BytesView slice must match standalone copy identically.
  let host = b"PREFIXbabababammiissiissiippiiSUFFIX"
  let slice = host[6:30]
  let copy = slice.to_owned()
  let view_sa = match
    build_suffix_array_view(slice, 1000L, suffix_test_budget(1000000L)) {
    Ok(sa) => sa
    Err(_) => abort("view build failed")
  }
  assert_eq(view_sa, naive_suffix_array(copy))
}

///|
test "suffix-sais-multilevel-recursion-and-periodic" {
  // Classic multi-level LMS collision triggers: alternating, Mississippi-like,
  // Fibonacci words, Thue-Morse words, and nested repeated blocks.
  assert_eq(suffix_test_build(b"babababa"), [8, 7, 5, 3, 1, 6, 4, 2, 0])
  for
    data in [
      repeat_bytes(b"ab", 64),
      repeat_bytes(b"ba", 64),
      repeat_bytes(b"\x00\xff", 128),
      repeat_bytes(b"\xff\x00", 128),
      repeat_bytes(b"mmiissiissiippii", 16),
      repeat_bytes(b"abacabad", 32),
      repeat_bytes(b"aaabaaac", 32),
    ] {
    let sa = suffix_test_build(data)
    suffix_test_complete(data, sa)
  }
  // Fibonacci words F_0..F_10 exact match against naive; F_11..F_14 full order check.
  for step in 0..<11 {
    suffix_test_small(fibonacci_bytes(step))
  }
  for step in 11..<15 {
    let fib = fibonacci_bytes(step)
    let sa = suffix_test_build(fib)
    suffix_test_complete(fib, sa)
  }
  // Thue-Morse T_0..T_7 exact match against naive; T_8..T_10 full order check.
  for order in 0..<8 {
    suffix_test_small(thue_morse_bytes(order))
  }
  for order in 8..<11 {
    let tm = thue_morse_bytes(order)
    let sa = suffix_test_build(tm)
    suffix_test_complete(tm, sa)
  }
}

///|
test "suffix-sais-linear-work-and-recursive-budget-exhaustion" {
  // Verify every SA-IS pass and recursive level enforces SortBudget cleanly.
  let recursive_input = thue_morse_bytes(7) // length 128, multi-level recursion
  let (expected_sa, exact_work) = suffix_work_used(recursive_input)
  suffix_test_complete(recursive_input, expected_sa)
  let exact_budget = suffix_test_budget(exact_work)
  assert_eq(
    build_suffix_array(recursive_input, 1000L, exact_budget),
    Ok(expected_sa),
  )
  assert_eq(exact_budget.remaining, 0L)
  // Step downwards across pass boundaries to prove every reservation fails closed.
  let mut probe = exact_work - 1L
  let mut distinct_failures = 0
  while probe > 0L {
    let b = suffix_test_budget(probe)
    match build_suffix_array(recursive_input, 1000L, b) {
      Ok(_) => abort("tight budget unexpectedly succeeded")
      Err(e) => {
        assert_eq(e.kind, ResourceLimitExceeded)
        assert_eq(e.stage, Sorting)
        assert_eq(e.field, Some("sort_remaining"))
        assert_true(b.remaining >= 0L)
        distinct_failures = distinct_failures + 1
        let consumed = probe - b.remaining
        if consumed == 0L {
          break
        }
        probe = consumed - 1L
      }
    }
  }
  // Multi-level recursion must hit at least 8 distinct reservation checkpoints.
  assert_true(distinct_failures >= 8)

  // Verify strictly linear O(n) work scaling across 1 KiB, 4 KiB, 16 KiB.
  for size in [1024, 4096, 16384] {
    let same = Bytes::from_array(Array::make(size, b'\x00'))
    let periodic = Bytes::from_array(Array::makei(size, i => (i % 7).to_byte()))
    let alt = repeat_bytes(b"\x00\xff", size / 2)
    let rand = suffix_test_random(size, 20261124U)
    let (_, w_same) = suffix_work_used(same)
    let (_, w_periodic) = suffix_work_used(periodic)
    let (_, w_alt) = suffix_work_used(alt)
    let (_, w_rand) = suffix_work_used(rand)
    let n64 = size.to_int64()
    // All-same hits lms_count == 1 (no second pass, no recursion): ~11N.
    assert_true(w_same < 13L * n64)
    // Periodic, alternating (recursive), and random all stay strictly O(n) < 35N.
    assert_true(w_periodic < 35L * n64)
    assert_true(w_alt < 35L * n64)
    assert_true(w_rand < 35L * n64)
  }
  // Also verify 64 KiB periodic/same fits well inside default max_sort_work (8,388,608).
  let periodic64 = Bytes::from_array(
    Array::makei(65536, i => (i % 7).to_byte()),
  )
  let (_, w_p64) = suffix_work_used(periodic64)
  assert_true(w_p64 < 2500000L)
}

///|
test "analyze-wb-overflow-saturation-and-zero-output-flag" {
  // abs_int64_saturating boundaries, including Int64::min saturation.
  assert_eq(abs_int64_saturating(0L), 0L)
  assert_eq(abs_int64_saturating(42L), 42L)
  assert_eq(abs_int64_saturating(-42L), 42L)
  assert_eq(abs_int64_saturating(ANALYZE_INT64_MAX), ANALYZE_INT64_MAX)
  assert_eq(abs_int64_saturating(ANALYZE_INT64_MIN + 1L), ANALYZE_INT64_MAX)
  assert_eq(abs_int64_saturating(ANALYZE_INT64_MIN), ANALYZE_INT64_MAX)

  // ratio_permille non-positive and fast-path cases.
  assert_eq(ratio_permille(0L, 100L), 0L)
  assert_eq(ratio_permille(-5L, 100L), 0L)
  assert_eq(ratio_permille(100L, 0L), 0L)
  assert_eq(ratio_permille(100L, -1L), 0L)
  assert_eq(ratio_permille(1L, 2L), 500L)
  assert_eq(ratio_permille(3L, 2L), 1500L)
  assert_eq(ratio_permille(1L, 3L), 333L)

  // ratio_permille exact binary-scaling branch (r > ANALYZE_INT64_MAX / 1000).
  let max_q = ANALYZE_INT64_MAX / 1000L
  assert_eq(ratio_permille(ANALYZE_INT64_MAX - 1L, ANALYZE_INT64_MAX), 999L)
  assert_eq(ratio_permille(ANALYZE_INT64_MAX / 2L, ANALYZE_INT64_MAX), 499L)
  assert_eq(
    ratio_permille(3_500_000_000_000_000_000L, 2_000_000_000_000_000_000L),
    1750L,
  )
  assert_eq(
    ratio_permille(999_999_999_999_999_999L, 1_000_000_000_000_000_000L),
    999L,
  )
  assert_eq(
    ratio_permille(123_456_789_000_000_000L, 1_000_000_000_000_000_000L),
    123L,
  )
  assert_eq(ratio_permille(max_q + 1L, 10_000_000_000_000_000L), 922L)

  // ratio_permille saturation when q > max_q or hi + lo > ANALYZE_INT64_MAX.
  assert_eq(ratio_permille(ANALYZE_INT64_MAX, 1L), ANALYZE_INT64_MAX)
  assert_eq(ratio_permille(max_q * 999L + 806L, 999L), ANALYZE_INT64_MAX - 1L)
  assert_eq(ratio_permille(max_q * 999L + 808L, 999L), ANALYZE_INT64_MAX)

  // evaluate_risk_flags ZERO_OUTPUT_NONTRIVIAL_PATCH threshold (74B canonical vs >74B / controls / expanded).
  let mk_deep = (
    patch_bytes : Int64,
    control_count : Int64,
    expanded_bytes : Int64,
  ) => {
    let header : PatchInfo = {
      patch_bytes,
      new_bytes: 0L,
      control_start: 32L,
      control_length: patch_bytes - 60L,
      diff_start: patch_bytes - 28L,
      diff_length: 14L,
      extra_start: patch_bytes - 14L,
      extra_length: 14L,
    }
    let deep : DeepPatchInfo = {
      header,
      control_count,
      diff_bytes: 0L,
      extra_bytes: 0L,
      expanded_bytes,
    }
    deep
  }
  let (lvl_empty, flags_empty) = evaluate_risk_flags(
    mk_deep(74L, 0L, 0L),
    42L,
    0L,
    0L,
    0L,
  )
  assert_eq(lvl_empty, Low)
  assert_eq(flags_empty.length(), 0)

  let (lvl_bloated, flags_bloated) = evaluate_risk_flags(
    mk_deep(75L, 0L, 0L),
    43L,
    0L,
    0L,
    0L,
  )
  assert_eq(lvl_bloated, Elevated)
  assert_eq(flags_bloated.length(), 1)
  assert_eq(flags_bloated[0].code, "ZERO_OUTPUT_NONTRIVIAL_PATCH")
  assert_eq(flags_bloated[0].severity, Elevated)

  let (lvl_ctrl, flags_ctrl) = evaluate_risk_flags(
    mk_deep(74L, 1L, 0L),
    42L,
    0L,
    0L,
    0L,
  )
  assert_eq(lvl_ctrl, Elevated)
  assert_eq(flags_ctrl.length(), 1)
  assert_eq(flags_ctrl[0].code, "ZERO_OUTPUT_NONTRIVIAL_PATCH")

  let (lvl_exp, flags_exp) = evaluate_risk_flags(
    mk_deep(74L, 0L, 1L),
    42L,
    0L,
    0L,
    0L,
  )
  assert_eq(lvl_exp, Elevated)
  assert_eq(flags_exp.length(), 1)
  assert_eq(flags_exp[0].code, "ZERO_OUTPUT_NONTRIVIAL_PATCH")
}
