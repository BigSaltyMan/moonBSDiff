// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
// Modified 2026-11-06 for MoonBSDiff; see README.md and changes.patch.

///|
/// The six bytes that open a block, and the six that close a stream. They are
/// decimal digits of pi and of Euler's number, which is what bzip2 chose to make
/// a damaged file obvious in a hex dump.
let block_marker : FixedArray[Int32] = [0x31, 0x41, 0x59, 0x26, 0x53, 0x59]

///|
let end_marker : FixedArray[Int32] = [0x17, 0x72, 0x45, 0x38, 0x50, 0x90]

///|
/// Which of the two markers comes next, or `None` if it is neither.
fn marker(bits : Bits) -> Int32? raise Fault {
  let seen : Array[Int32] = []
  for _ in 0..<6 {
    seen.push(need(bits, 8))
  }
  let mut is_block = true
  let mut is_end = true
  for i in 0..<6 {
    if seen[i] != block_marker[i] {
      is_block = false
    }
    if seen[i] != end_marker[i] {
      is_end = false
    }
  }
  if is_block {
    Some(0)
  } else if is_end {
    Some(1)
  } else {
    None
  }
}
