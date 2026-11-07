// Generated from testdata/matching/segments.json; checked independently by Python.

///|
test "matching-compact-vector-overlap" {
  let old = b"ABBCBCAABBAAACABBCACBACBCAAABABCBCAABACB"
  let new = b"ABBCBCAABBACCCABCBCAABACB"
  let sa = suffix_test_build(old)
  let segments = matching_test_plan(old, new, sa)
  matching_check_plan(old, new, segments)
  let expected : Array[(Int32, Int32, Int32, Int32, Int64)] = [
    (0, 0, 14, 0, 15L),
    (14, 29, 11, 0, -9L),
  ]
  assert_eq(segments.length(), expected.length())
  for i in 0..<segments.length() {
    let s = segments[i]
    assert_eq(
      (s.new_start, s.old_start, s.diff_length, s.extra_length, s.seek),
      expected[i],
    )
  }
}

///|
test "matching-compact-vector-block-move" {
  let old = b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  let new = b"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  let sa = suffix_test_build(old)
  let segments = matching_test_plan(old, new, sa)
  matching_check_plan(old, new, segments)
  let expected : Array[(Int32, Int32, Int32, Int32, Int64)] = [
    (0, 0, 0, 0, 32L),
    (0, 32, 32, 0, -64L),
    (32, 0, 32, 0, -32L),
  ]
  assert_eq(segments.length(), expected.length())
  for i in 0..<segments.length() {
    let s = segments[i]
    assert_eq(
      (s.new_start, s.old_start, s.diff_length, s.extra_length, s.seek),
      expected[i],
    )
  }
}

///|
test "matching-compact-vector-unmatched" {
  let old = b"AAAA"
  let new = b"zzzz"
  let sa = suffix_test_build(old)
  let segments = matching_test_plan(old, new, sa)
  matching_check_plan(old, new, segments)
  let expected : Array[(Int32, Int32, Int32, Int32, Int64)] = [(0, 0, 0, 4, 0L)]
  assert_eq(segments.length(), expected.length())
  for i in 0..<segments.length() {
    let s = segments[i]
    assert_eq(
      (s.new_start, s.old_start, s.diff_length, s.extra_length, s.seek),
      expected[i],
    )
  }
}
