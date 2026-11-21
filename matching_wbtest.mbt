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

///|
// Independent non-LCP reference search implementing the exact lower-bound and
// right-preferring equal-length tie-break specification from i = 0 every step.
fn matching_reference_search(
  old : Bytes,
  new : Bytes,
  sa : Array[Int32],
  at : Int32,
) -> (Int32, Int32) {
  let mut lo = 0
  let mut hi = sa.length()
  while lo < hi {
    let mid = lo + (hi - lo) / 2
    let pos = sa[mid]
    let old_rem = old.length() - pos
    let new_rem = new.length() - at
    let cap = if old_rem < new_rem { old_rem } else { new_rem }
    let mut i = 0
    let mut cmp = 0
    let mut diff = false
    while i < cap {
      if old[pos + i] != new[at + i] {
        cmp = if old[pos + i].to_int() < new[at + i].to_int() { -1 } else { 1 }
        diff = true
        break
      }
      i = i + 1
    }
    if !diff {
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
    } else {
      hi = mid
    }
  }
  let lcp_at = fn(pos : Int32) -> Int32 {
    let mut i = 0
    while i < old.length() - pos &&
          i < new.length() - at &&
          old[pos + i] == new[at + i] {
      i = i + 1
    }
    i
  }
  let mut pos = old.length()
  let mut length = 0
  if lo > 0 {
    pos = sa[lo - 1]
    length = lcp_at(pos)
  }
  if lo < sa.length() {
    let right = lcp_at(sa[lo])
    if right >= length {
      pos = sa[lo]
      length = right
    }
  }
  (pos, length)
}

///|
fn matching_repetitive_random(
  length : Int32,
  alphabet : Int32,
  seed : UInt32,
) -> Bytes {
  let mut state = seed
  let bytes : Array[Byte] = []
  let symbols : Array[Byte] = [b'\x00', b'\x01', b'\x41', b'\xff']
  for _ in 0..<length {
    state = state * 1664525U + 1013904223U
    let idx = ((state >> 24).reinterpret_as_int() % alphabet + alphabet) %
      alphabet
    bytes.push(symbols[idx])
  }
  Bytes::from_array(bytes)
}

///|
test "matching-compact-lcp-reference-equivalence" {
  // Exhaustive binary strings of length 0..3: exact (pos, length) equivalence.
  let words : Array[Bytes] = []
  let mut count = 1
  for length in 0..<4 {
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
  for old in words {
    let sa = suffix_test_build(old)
    for new in words {
      for at in 0..<=new.length() {
        assert_eq(
          matching_test_search(old, new, sa, at),
          matching_reference_search(old, new, sa, at),
        )
      }
    }
  }
  // Boundary & high-repetition cases including queries beyond sa[last],
  // exact matches at sa[last], proper prefixes, and equal-length ties.
  for
    (old, new) in [
      (b"aaaa", b"aaaab"),
      (b"aaaa", b"aaaa"),
      (b"aaaa", b"aa"),
      (b"aaaa", b"a"),
      (b"\x00\x00\x00\x00", b"\x00\x00\x00\x01"),
      (b"abababababab", b"abababacabab"),
      (
        matching_repetitive_random(64, 2, 20261121U),
        matching_repetitive_random(64, 2, 20261122U),
      ),
      (
        matching_repetitive_random(64, 3, 20261123U),
        matching_repetitive_random(64, 3, 20261124U),
      ),
    ] {
    let sa = suffix_test_build(old)
    for at in 0..<=new.length() {
      assert_eq(
        matching_test_search(old, new, sa, at),
        matching_reference_search(old, new, sa, at),
      )
    }
  }
}

///|
test "matching-compact-repeated-prefix-regression" {
  let limits = Limits::for_diff()
  let apply_limits = Limits::for_apply()
  let zeros_2k = Bytes::from_array(Array::make(2048, b'\x00'))
  let head = b"HEAD0123456789AB"
  let tail = b"TAIL"
  let as_2k = Bytes::from_array(Array::make(2048, b'A'))
  let as_2k_tail = Bytes::from_array(Array::make(2047, b'A')) + b"B"
  for
    (old, new) in [
      // 1-byte insertion before a 2 KiB zero run: previously exceeded
      // Limits::for_diff().max_match_work (8,388,608) at ~26.2M work units.
      (zeros_2k, b"X" + zeros_2k),
      (head + zeros_2k + tail, head + b"!" + zeros_2k + tail),
      (as_2k, as_2k_tail),
      (as_2k, as_2k),
    ] {
    let old_snap = old.to_array()
    let new_snap = new.to_array()
    let sort = suffix_test_budget(limits.max_sort_work)
    let work = matching_test_budget(limits.max_match_work)
    let patch = match generate_patch(old, new, limits, sort, work) {
      Ok(p) => p
      Err(_) => abort("2 KiB repeated-prefix diff exhausted default limits")
    }
    assert_true(limits.max_match_work - work.remaining < 6500000L)
    assert_eq(apply(old, patch, apply_limits), Ok(new))
    assert_eq(diff(old, new, limits), Ok(patch))
    assert_eq(old.to_array(), old_snap)
    assert_eq(new.to_array(), new_snap)
  }
}

///|
test "matching-native-lcp-exhaustive-and-repetitive-equivalence" {
  // Full 2-symbol exhaustive (length 0..4 => 31 words, 961 pairs, 3999 queries).
  let words2 : Array[Bytes] = []
  let mut count2 = 1
  for length in 0..<5 {
    for code in 0..<count2 {
      let mut value = code
      let bytes : Array[Byte] = []
      for _ in 0..<length {
        bytes.push(if value % 2 == 0 { b'\x00' } else { b'\xff' })
        value = value / 2
      }
      words2.push(Bytes::from_array(bytes))
    }
    count2 = count2 * 2
  }
  let mut checked = 0
  for old in words2 {
    let sa = suffix_test_build(old)
    for new in words2 {
      for at in 0..<=new.length() {
        assert_eq(
          matching_test_search(old, new, sa, at),
          matching_reference_search(old, new, sa, at),
        )
        checked = checked + 1
      }
    }
  }
  assert_eq(checked, 3999)
  // Full 3-symbol exhaustive (length 0..3 => 40 words, 1600 pairs).
  let words3 : Array[Bytes] = []
  let mut count3 = 1
  for length in 0..<4 {
    for code in 0..<count3 {
      let mut value = code
      let bytes : Array[Byte] = []
      for _ in 0..<length {
        bytes.push([b'\x00', b'\x01', b'\xff'][value % 3])
        value = value / 3
      }
      words3.push(Bytes::from_array(bytes))
    }
    count3 = count3 * 3
  }
  for old in words3 {
    let sa = suffix_test_build(old)
    for new in words3 {
      for at in 0..<=new.length() {
        assert_eq(
          matching_test_search(old, new, sa, at),
          matching_reference_search(old, new, sa, at),
        )
      }
    }
  }
  // High-repetition random pairs (2-, 3-, 4-symbol alphabets, lengths up to 128).
  for i in 0..<48 {
    let alphabet = 2 + i % 3
    let len_old = 16 + i * 2
    let len_new = 16 + (47 - i) * 2
    let old = matching_repetitive_random(
      len_old,
      alphabet,
      20261125U + i.reinterpret_as_uint(),
    )
    let new = matching_repetitive_random(
      len_new,
      alphabet,
      20261225U + i.reinterpret_as_uint(),
    )
    let sa = suffix_test_build(old)
    for at in 0..<=new.length() {
      assert_eq(
        matching_test_search(old, new, sa, at),
        matching_reference_search(old, new, sa, at),
      )
    }
  }
}

///|
test "matching-native-repeated-prefix-large-regression" {
  let limits = Limits::for_diff()
  let apply_limits = Limits::for_apply()
  let zeros_2k = Bytes::from_array(Array::make(2048, b'\x00'))
  let body_14k = suffix_test_random(14336, 2026112101U)
  let body_62k = suffix_test_random(63487, 2026112102U)
  let a_16k = Bytes::from_array(Array::make(16384, b'A'))
  let a_16k_tail = Bytes::from_array(Array::make(16383, b'A')) + b"B"
  let a_64k = Bytes::from_array(Array::make(65536, b'A'))
  let a_64k_tail = Bytes::from_array(Array::make(65535, b'A')) + b"B"
  for
    (old, new) in [
      (body_14k + zeros_2k, body_14k + b"!" + zeros_2k),
      (body_62k + zeros_2k, body_62k + b"!" + zeros_2k),
      (a_16k, a_16k_tail),
      (a_64k, a_64k_tail),
    ] {
    let patch = match diff(old, new, limits) {
      Ok(p) => p
      Err(_) => abort("large high-repetition diff exhausted default limits")
    }
    assert_eq(apply(old, patch, apply_limits), Ok(new))
  }
}
