///|
fn assert_complete_huffman_lengths(
  lengths : Array[Int32],
  expected_count : Int32,
  expected_longest : Int32,
) -> Unit raise {
  assert_eq(lengths.length(), expected_count)
  let mut kraft = 0
  let mut longest = 0
  for length in lengths {
    assert_true(length >= 1 && length <= 20)
    kraft += 1 << (20 - length)
    longest = Int32::max(longest, length)
  }
  assert_eq(longest, expected_longest)
  assert_eq(kraft, 1 << 20)
}

///|
test "bzip2 length limit preserves complete Huffman tables" {
  let weights = [1, 1]
  // Fibonacci alphabets give uncapped depths n - 1. This covers the
  // unrestricted tree, the shallow clamp, and the previously under-repaired
  // depths 23 through 25.
  for n in 3..<=26 {
    weights.push(weights[n - 2] + weights[n - 3])
    if n >= 20 {
      assert_complete_huffman_lengths(
        lengths_from(weights, 20),
        n,
        Int32::min(n - 1, 20),
      )
    }
  }
}

///|
test "bzip2 length limit handles zero weights mapped to one at depth >= 23" {
  // Unused symbols carry weight 0 and are mapped to 1 inside lengths_from.
  // Leading [0, 0] followed by Fibonacci weights 2..46368 produces uncapped
  // depths 23..25 and exercises clamping + Kraft repair.
  let weights = [0, 0, 2, 3]
  for n in 5..<=26 {
    weights.push(weights[n - 2] + weights[n - 3])
    if n >= 24 {
      assert_complete_huffman_lengths(lengths_from(weights, 20), n, 20)
    }
  }
}

///|
test "bzip2 length limit repairs full 258-symbol alphabet above depth 20" {
  // 234 minimal symbols (including zero weights mapped to 1) merge first into
  // a depth-8 subtree of total weight 234; 24 Fibonacci-scaled weights above
  // 234 push the uncapped tree depth well past 23 while staying within Int32.
  let weights : Array[Int32] = []
  for i in 0..<234 {
    weights.push(if i % 2 == 0 { 0 } else { 1 })
  }
  let mut a = 234
  let mut b = 235
  for _ in 0..<24 {
    weights.push(a)
    let next = a + b
    a = b
    b = next
  }
  assert_eq(weights.length(), 258)
  assert_complete_huffman_lengths(lengths_from(weights, 20), 258, 20)
}
