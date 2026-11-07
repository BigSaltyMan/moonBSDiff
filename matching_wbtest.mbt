///|
fn matching_test_budget(amount : Int64) -> MatchBudget {
  match matching_budget(amount) {
    Ok(b) => b
    Err(_) => abort("budget creation failed")
  }
}

///|
fn matching_test_search(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  at : Int32,
) -> (Int32, Int32) {
  match longest_match(old, new, sa, at, matching_test_budget(100000000L)) {
    Ok(v) => v
    Err(_) => abort("query failed")
  }
}

///|
fn matching_test_plan(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
) -> Array[DiffSegment] {
  match
    select_segments(old, new, sa, 100000L, matching_test_budget(100000000L)) {
    Ok(v) => v
    Err(_) => abort("plan failed")
  }
}

///|
// Direct test-only candidate enumeration, independent of binary search/comparison.
fn matching_naive_length(old : Bytes, new : Bytes, at : Int32) -> Int32 {
  let mut best = 0
  for pos in 0..<=old.length() {
    let mut length = 0
    while pos + length < old.length() &&
          at + length < new.length() &&
          old[pos + length] == new[at + length] {
      length = length + 1
    }
    if length > best {
      best = length
    }
  }
  best
}

///|
fn matching_check_query(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  at : Int32,
) -> Unit {
  let (pos, length) = matching_test_search(old, new, sa, at)
  try! assert_eq(length, matching_naive_length(old, new, at))
  try! assert_true(pos >= 0 && pos <= old.length())
  try! assert_true(length <= old.length() - pos && length <= new.length() - at)
  for i in 0..<length {
    try! assert_eq(old[pos + i], new[at + i])
  }
}

///|
fn matching_check_plan(
  old : Bytes,
  new : Bytes,
  plan : Array[DiffSegment],
) -> Unit {
  let mut covered = 0
  let mut cursor = 0L
  let mut equal = 0
  for segment in plan {
    try! assert_eq(segment.new_start, covered)
    try! assert_eq(segment.old_start.to_int64(), cursor)
    try! assert_true(
      segment.old_start >= 0 && segment.old_start <= old.length(),
    )
    try! assert_true(segment.diff_length >= 0 && segment.extra_length >= 0)
    try! assert_true(segment.diff_length <= old.length() - segment.old_start)
    try! assert_true(segment.diff_length <= new.length() - covered)
    for i in 0..<segment.diff_length {
      if old[segment.old_start + i] == new[covered + i] {
        equal = equal + 1
      }
    }
    covered = covered + segment.diff_length
    try! assert_true(segment.extra_length <= new.length() - covered)
    covered = covered + segment.extra_length
    cursor = cursor + segment.diff_length.to_int64() + segment.seek
    try! assert_true(cursor >= 0L && cursor <= old.length().to_int64())
  }
  try! assert_eq(covered, new.length())
  if new.length() == 0 {
    try! assert_eq(plan.length(), 0)
  }
  try! assert_true(equal <= new.length())
}

///|
fn matching_same_plan(a : Array[DiffSegment], b : Array[DiffSegment]) -> Unit {
  try! assert_eq(a.length(), b.length())
  for i in 0..<a.length() {
    try! assert_eq(
      (
        a[i].new_start,
        a[i].old_start,
        a[i].diff_length,
        a[i].extra_length,
        a[i].seek,
      ),
      (
        b[i].new_start,
        b[i].old_start,
        b[i].diff_length,
        b[i].extra_length,
        b[i].seek,
      ),
    )
  }
}

///|
test "matching-compact-query-prefix-and-ties" {
  for
    (old, new) in [
      (b"", b""),
      (b"", b"abc"),
      (b"aaaa", b"aaaa"),
      (b"banana", b"ana"),
      (b"abc", b"abcX"),
      (b"abc", b"zabc"),
      (b"\x00\xff\x00", b"\xff\x00"),
    ] {
    let sa = suffix_test_build(old)
    let before = sa.copy()
    for at in 0..<=new.length() {
      matching_check_query(old, new, sa, at)
    }
    assert_eq(sa, before)
    assert_eq(
      matching_test_search(old, new, sa, new.length()),
      (old.length(), 0),
    )
  }
  assert_eq(
    matching_test_search(b"aaaa", b"aaaa", suffix_test_build(b"aaaa"), 0),
    (0, 4),
  )
  // Lower-bound right candidate wins equal length: suffix a at position 3.
  assert_eq(
    matching_test_search(b"aaaa", b"a", suffix_test_build(b"aaaa"), 0),
    (3, 1),
  )
  assert_eq(
    matching_test_search(b"abcabc", b"abc", suffix_test_build(b"abcabc"), 0),
    (3, 3),
  )
}

///|
test "matching-compact-scoring-and-overlap" {
  // Scores 2*matches-length: 1,2,1,2. Strict improvement keeps length 2.
  assert_eq(
    try! forward_choice(b"abXd", b"abYd", 0, 0, 4, matching_test_budget(100L)),
    2,
  )
  assert_eq(
    try! backward_choice(b"dXba", b"dYba", 4, 4, 0, matching_test_budget(100L)),
    2,
  )
  // New abcd; front abXX, back YYcd. Best assignment is two bytes each.
  assert_eq(
    try! overlap_cut(
      b"abXXYYcd",
      b"abcd",
      0,
      4,
      0,
      4,
      matching_test_budget(100L),
    ),
    2,
  )
  assert_eq(
    try! overlap_cut(
      b"abcdabcd",
      b"abcd",
      0,
      4,
      0,
      4,
      matching_test_budget(100L),
    ),
    0,
  )
}

///|
test "matching-compact-plan-structure-and-reuse" {
  let base = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  for
    (old, new) in [
      (b"", b""),
      (b"", b"new"),
      (base, b""),
      (base, base),
      (b"AAAA", b"zzzz"),
      (base, b"0123456789ABCD!FGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"),
      (
        base, b"PREFIX0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzSUFFIX",
      ),
      (base, b"0123456789ABCDEFGHIJKLMNOPQRSTabcdefghijklmnopqrstuvwx"),
      (
        base, b"0123456789ABCDEFGHIJ++KLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
      ),
      (base, b"0123456789ABCDEFG"),
      (b"ABABABABABABABABABABABAB", b"ABABABXABABABABABABABABABAB"),
      (b"\x00\xff\x01", b"\xff\x01\x00"),
    ] {
    let sa = suffix_test_build(old)
    let plan = matching_test_plan(old, new, sa)
    matching_check_plan(old, new, plan)
    matching_same_plan(plan, matching_test_plan(old, new, sa))
  }
  let identical = matching_test_plan(base, base, suffix_test_build(base))
  assert_eq(identical.length(), 1)
  assert_eq(
    (
      identical[0].new_start,
      identical[0].old_start,
      identical[0].diff_length,
      identical[0].extra_length,
    ),
    (0, 0, base.length(), 0),
  )
  let changed = b"0123456789ABCD!FGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  let plan = matching_test_plan(base, changed, suffix_test_build(base))
  let mut reused = 0
  let mut residuals = 0
  for s in plan {
    reused = reused + s.diff_length
    for i in 0..<s.diff_length {
      if base[s.old_start + i] != changed[s.new_start + i] {
        residuals = residuals + 1
      }
    }
  }
  assert_true(reused >= 50)
  assert_true(residuals > 0)
}

///|
test "matching-compact-state-and-limits" {
  let old = b"banana\x00\xff"
  let new = b"ana\x00\xffbanana"
  let sa = suffix_test_build(old)
  let snapshot = sa.copy()
  let old_bytes = old.to_array()
  let new_bytes = new.to_array()
  let plan = matching_test_plan(old, new, sa)
  let shared = matching_test_budget(1L)
  for _ in 0..<2 {
    match longest_match(old, new, sa, 0, shared) {
      Ok(_) => abort("budget ignored")
      Err(e) => {
        assert_eq(e.kind, ResourceLimitExceeded)
        assert_eq(e.stage, Matching)
        assert_eq(e.field, Some("match_remaining"))
        assert_eq(e.offset, None)
      }
    }
    assert_eq(shared.remaining, 0L)
  }
  for at in [-1, new.length() + 1] {
    match longest_match(old, new, sa, at, matching_test_budget(100L)) {
      Ok(_) => abort("bad query accepted")
      Err(e) => assert_eq(e.field, Some("new_position"))
    }
  }
  match select_segments(old, new, sa, 0L, matching_test_budget(100000L)) {
    Ok(_) => abort("segment limit ignored")
    Err(e) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.field, Some("segments"))
    }
  }
  match select_segments(old, new, sa, -1L, matching_test_budget(100L)) {
    Ok(_) => abort("negative cap accepted")
    Err(e) => assert_eq(e.kind, InvalidConfiguration)
  }
  match matching_budget(-1L) {
    Ok(_) => abort("negative work accepted")
    Err(e) => {
      assert_eq(e.kind, InvalidConfiguration)
      assert_eq(e.stage, Matching)
    }
  }
  let exact = matching_test_budget(1L)
  assert_eq(longest_match(b"", b"X", [0], 0, exact), Ok((0, 0)))
  assert_eq(exact.remaining, 0L)
  match longest_match(b"", b"X", [0], 0, exact) {
    Ok(_) => abort("budget reset")
    Err(e) => assert_eq(e.kind, ResourceLimitExceeded)
  }
  for array in [[], [0, 999]] {
    match longest_match(b"A", b"A", array, 0, matching_test_budget(100L)) {
      Ok(_) => abort("invalid index accepted")
      Err(e) => {
        assert_eq(e.kind, InvalidField)
        assert_eq(e.stage, Matching)
      }
    }
  }
  match select_segments(old, new, sa, 2147483648L, matching_test_budget(100L)) {
    Ok(_) => abort("invalid segment cap accepted")
    Err(e) => assert_eq(e.kind, InvalidConfiguration)
  }
  let other = matching_test_plan(b"A", b"z", suffix_test_build(b"A"))
  matching_check_plan(b"A", b"z", other)
  matching_same_plan(plan, matching_test_plan(old, new, sa))
  assert_eq(old.to_array(), old_bytes)
  assert_eq(new.to_array(), new_bytes)
  assert_eq(sa, snapshot)
}

///|
test "matching-native-exhaustive" {
  let words : Array[Bytes] = []
  let mut count = 1
  for length in 0..<5 {
    for code in 0..<count {
      let mut value = code
      let bytes : Array[Byte] = []
      for _ in 0..<length {
        bytes.push(if value % 2 == 0 { b'\x00' } else { b'\xff' })
        value = value / 2
      }
      words.push(Bytes::from_array(bytes))
    }
    count = count * 2
  }
  assert_eq(words.length(), 31)
  let mut queries = 0
  let mut plans = 0
  for old in words {
    let sa = suffix_test_build(old)
    for new in words {
      for at in 0..<=new.length() {
        matching_check_query(old, new, sa, at)
        queries = queries + 1
      }
      plans = plans + 1
      matching_check_plan(old, new, matching_test_plan(old, new, sa))
    }
  }
  assert_eq(queries, 3999)
  assert_eq(plans, 961)
}

///|
test "matching-native-random-and-repetition" {
  for i in 0..<64 {
    let old = suffix_test_random(i, 20261107U + i.reinterpret_as_uint())
    let new = suffix_test_random(63 - i, 20261108U + i.reinterpret_as_uint())
    let sa = suffix_test_build(old)
    for at in 0..<=new.length() {
      matching_check_query(old, new, sa, at)
    }
    matching_check_plan(old, new, matching_test_plan(old, new, sa))
  }
  for n in [256, 2048, 8192] {
    let old = Bytes::from_array(Array::make(n, b'A'))
    let new = old + b"B"
    let sa = suffix_test_build(old)
    let plan = matching_test_plan(old, new, sa)
    matching_check_plan(old, new, plan)
    let mut reuse = 0
    for s in plan {
      reuse = reuse + s.diff_length
    }
    assert_eq(reuse, n)
  }
}
