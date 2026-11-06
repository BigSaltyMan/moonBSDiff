// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
// Modified 2026-11-06 for MoonBSDiff; see README.md and changes.patch.

///|
/// bzip2 reads its bits most significant first. That is the opposite of DEFLATE,
/// which is the whole reason this is a file of its own rather than a reuse of
/// `deflate/bits.mbt`: the two formats disagree on which end of a byte the first
/// bit lives, and mixing them silently produces streams that only their author
/// can read.
priv struct Bits {
  data : BytesView
  mut at : Int32
  mut acc : UInt32
  mut held : Int32
}

///|
fn Bits::new(data : BytesView) -> Bits {
  { data, at: 0, acc: 0, held: 0, }
}

///|
/// `n` bits, or `None` when the slice has fewer left.
///
/// Twenty-four is the widest single read the format asks for, so one accumulator
/// always holds what is pending and no read has to be split.
fn Bits::take(self : Bits, n : Int32) -> Int32? {
  while self.held < n {
    if self.at >= self.data.length() {
      return None
    }
    self.acc = (self.acc << 8) | self.data[self.at].to_uint()
    self.at += 1
    self.held += 8
  }
  self.held -= n
  let mask = if n == 0 { 0U } else { (1U << n) - 1U }
  Some(((self.acc >> self.held) & mask).reinterpret_as_int())
}

///|
/// Thirty-two bits, as two sixteen-bit halves.
///
/// A mask built as `(1 << 32) - 1` is zero in thirty-two-bit arithmetic, so the
/// single-read path cannot express a full word — and every checksum in the format
/// is one.
fn Bits::take_word(self : Bits) -> UInt32? {
  match self.take(16) {
    None => None
    Some(high) =>
      match self.take(16) {
        None => None
        Some(low) =>
          Some((high.reinterpret_as_uint() << 16) | low.reinterpret_as_uint())
      }
  }
}

///|
/// How many bytes were read out of the slice, which is where the reader got to
/// rather than where the last bit it used ended.
fn Bits::used(self : Bits) -> Int32 {
  self.at
}
