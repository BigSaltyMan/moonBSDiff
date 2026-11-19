// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
// Modified 2026-11-19 for MoonBSDiff; see README.md and encoder-changes.patch.

///|
/// The other half: a sink that fills a byte from the top down.
priv struct Sink {
  out : Array[Byte]
  mut acc : UInt32
  mut held : Int32
}

///|
fn Sink::new() -> Sink {
  { out: [], acc: 0, held: 0, }
}

///|
fn Sink::bits(self : Sink, value : Int32, n : Int32) -> Unit {
  if n == 0 {
    return
  }
  let mask = (1U << n) - 1U
  self.acc = (self.acc << n) | (value.reinterpret_as_uint() & mask)
  self.held += n
  while self.held >= 8 {
    self.held -= 8
    self.out.push(
      ((self.acc >> self.held) & 0xFFU).reinterpret_as_int().to_byte(),
    )
  }
}

///|
/// Thirty-two bits, as two sixteen-bit halves, for the same reason the reader
/// takes them that way.
fn Sink::word(self : Sink, value : UInt32) -> Unit {
  self.bits((value >> 16).reinterpret_as_int(), 16)
  self.bits((value & 0xFFFFU).reinterpret_as_int(), 16)
}

///|
/// The bytes written so far, and forget them.
///
/// A streaming writer hands back what it has after every call rather than keeping
/// it, so what is held between calls is a block and not a stream.
fn Sink::drain(self : Sink) -> Bytes {
  let made = Bytes::from_array(self.out)
  self.out.clear()
  made
}

///|
/// Pad the final byte of the stream with zeros.
fn Sink::finish(self : Sink) -> Bytes {
  if self.held > 0 {
    self.out.push(
      ((self.acc << (8 - self.held)) & 0xFFU).reinterpret_as_int().to_byte(),
    )
    self.held = 0
  }
  Bytes::from_array(self.out)
}
