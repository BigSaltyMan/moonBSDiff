// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
// Modified 2026-11-19 for MoonBSDiff; see README.md and encoder-changes.patch.

///|
/// A streaming compressor that holds one RLE block and a pending run.
/// The run can span feeds and is folded into a block before its CRC is updated.
struct Writer {
  level : Int32
  sink : Sink
  /// The block being filled, after the run-length stage.
  mut block : Array[Byte]
  mut crc : BlockCrc
  mut combined : UInt32
  /// The byte the current run is made of, or -1 between runs.
  mut run_byte : Int32
  mut run_len : Int32
  mut closed : Bool
}

///|
pub fn Writer::new(level~ : Int32 = 9) -> Writer {
  let size = if level < 1 { 1 } else if level > 9 { 9 } else { level }
  let sink = Sink::new()
  for b in [0x42, 0x5A, 0x68, 0x30 + size] {
    sink.bits(b, 8)
  }
  {
    level: size,
    sink,
    block: [],
    crc: BlockCrc::new(),
    combined: 0U,
    run_byte: -1,
    run_len: 0,
    closed: false,
  }
}

///|
/// Fold the current run into the block, as four bytes and a count or as itself.
fn Writer::flush_run(self : Writer) -> Unit {
  if self.run_byte < 0 {
    return
  }
  let len = self.run_len
  let encoded_len = if len < 4 { len } else { 5 }
  // The run, including its uncompressed CRC contribution, belongs to one block.
  if encoded_len > block_size(self.level) - self.block.length() {
    self.emit()
  }
  for _ in 0..<len {
    self.crc.push_byte(self.run_byte)
  }
  if len < 4 {
    for _ in 0..<len {
      self.block.push(self.run_byte.to_byte())
    }
  } else {
    for _ in 0..<4 {
      self.block.push(self.run_byte.to_byte())
    }
    self.block.push((len - 4).to_byte())
  }
  self.run_byte = -1
  self.run_len = 0
}

///|
/// Hand the block over and start another.
fn Writer::emit(self : Writer) -> Unit {
  let crc = self.crc.finish()
  write_block(self.sink, self.block, crc)
  self.combined = ((self.combined << 1) | (self.combined >> 31)) ^ crc
  self.block = []
  self.crc = BlockCrc::new()
}

///|
pub fn Writer::push(self : Writer, data : BytesView) -> Bytes {
  if self.closed {
    return b""
  }
  let max = block_size(self.level)
  for b in data {
    let byte = b.to_int()
    if self.run_byte == byte && self.run_len < 255 {
      self.run_len += 1
    } else {
      self.flush_run()
      self.run_byte = byte
      self.run_len = 1
    }
    if self.block.length() >= max {
      self.emit()
    }
  }
  self.sink.drain()
}

///|
pub fn Writer::finish(self : Writer) -> Bytes {
  if self.closed {
    return b""
  }
  self.closed = true
  self.flush_run()
  if self.block.length() > 0 {
    self.emit()
  }
  for b in end_marker {
    self.sink.bits(b, 8)
  }
  self.sink.word(self.combined)
  self.sink.finish()
}
