///|
test "stream pull: source refill, paused runs, strict end, budget" {
  let plain = b"ABCD\x00\xff" +
    Bytes::make(8193, 0x5a) +
    Bytes::from_array(Array::makei(4352, i => (i % 256).to_byte()))
  let packed = b"\x42\x5a\x68\x31\x31\x41\x59\x26\x53\x59\x4d\xb0\xe3\x3e\x00\x02\x29\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xd0\x03\x7e\x00\x00\x00\x12\x60\x00\x98\x00\x09\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x09\x30\x00\x4c\x00\x04\xc0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x98\x00\x26\x00\x02\x60\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x4c\x00\x13\x00\x01\x30\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x29\x55\x54\x00\x00\x00\x00\x00\x13\x00\x00\x00\x00\x00\x04\xc0\x00\x00\x00\x00\x4c\x00\x00\x00\x06\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x4c\x69\x90\x60\x43\x47\xc1\xa1\x83\xc3\x08\x86\x13\x0c\x2a\x18\x5c\x30\xc8\x61\xb0\xc3\xa1\x87\xc3\x10\x86\x23\x0c\x4a\x18\x9c\x31\x48\x62\xb0\xc5\xa1\x8b\xc3\x18\x86\x33\x0c\x6a\x18\xdc\x31\xc8\x63\xb0\xc7\xa1\x8f\xc3\x20\x86\x43\x0f\xfb\x91\xc3\x23\x86\x49\x0c\x96\x19\x34\x32\x78\x65\x10\xca\x61\x95\x43\x2b\x86\x59\x0c\xb6\x19\x74\x32\xf8\x7f\xc8\x66\x10\xcc\x61\x99\x43\x33\x86\x69\x0c\xd6\x19\xb4\x33\x78\x67\x10\xce\x61\x9d\x43\x3b\x86\x79\x0c\xf6\x19\xf4\x33\xf8\x68\x10\xd0\x61\xa1\x43\x43\x86\x89\x0d\x13\x45\x86\x8c\x8d\x1d\x1a\x42\x34\x88\x69\x30\xd2\xa1\xa5\xc3\x4c\x86\x9b\x0d\x3a\x1a\x7c\x35\x08\x6a\x30\xd4\xa1\xa9\xc3\x54\x86\xab\x0d\x5a\x1a\xbc\x35\x88\x6b\x30\xd6\xa1\xad\xc3\x5c\x86\x81\x7f\x40\xc7\xb0\x50\x35\xd8\x60\x90\xb5\xe8\x6b\xf0\xd8\x21\xb0\xc3\x62\x86\xc7\x0d\x92\x1b\x2c\x36\x68\x6c\xf0\xda\x21\xb4\xc3\x6a\x86\xd7\x0d\xb2\x1b\x6c\x36\xe8\x6d\xf0\xdc\x21\xb8\xc3\x72\x86\xe7\x0d\xd2\x1b\xac\x37\x68\x6e\xf0\xde\x21\xbc\xc3\x7a\x86\xf7\x0d\xf2\x1b\xec\x37\xe8\x6f\xf0\xe0\x21\xc0\xc3\x82\x87\x07\x0f\xfd\x0e\x12\x1c\x2c\x38\x68\x70\xf0\xe2\x21\xc4\xc3\x8a\x87\x17\x0e\x32\x1c\x6c\x38\xe8\x71\xf0\xe4\x21\xc8\xc3\x92\x87\x27\x0e\x52\x1c\xac\x39\x68\x72\xf0\xe6\x21\xcc\xc3\x9a\x87\x37\x0e\x72\x1c\xec\x39\xe8\x73\xf0\xe8\x21\xd0\xc3\xa2\x86\x02\x1d\x1c\x3a\x48\x74\xb0\xe9\xa1\xd3\xc3\xa8\x87\x53\x0e\xaa\x1d\x5c\x3a\xc8\x75\xb0\xeb\xa1\xd7\xc3\xb0\x87\x63\x0e\xca\x1d\x9c\x3b\x48\x76\xb0\xed\xa1\xdb\xc3\xb8\x87\x73\x0e\xea\x1d\xdc\x3b\xc8\x77\xb0\xef\xa1\xdf\xc3\xc0\x87\x83\x0f\x0a\x1e\x1c\x3c\x48\x78\xb0\xf1\xa1\xe3\xc3\xc8\x87\x93\x0f\x2a\x1e\x5c\x3c\xc8\x79\xb0\xf3\xa1\xe7\xc3\xd0\x87\xa3\x0f\x4a\x1e\x9c\x3d\x48\x7a\xb0\xf5\xa1\xeb\xc3\xd8\x87\xb3\x0f\x6a\x1e\xdc\x3d\xc8\x7b\xb0\xf7\xa1\xef\xc3\xe0\x87\xc3\x0f\x8a\x1f\x1c\x3e\x48\x7c\xb0\xf9\xa1\xf3\xc3\xe8\x87\xd3\x0f\xaa\x1f\x5c\x3e\xc8\x7d\xb0\xfb\xa1\xf7\xc3\xf0\x87\xe3\x0f\xca\x1f\x9c\x3f\x48\x7e\xb0\xfd\xa1\xfb\xc3\xf8\x87\xf3\x0f\xff\x0e\x7c\x1f\xd4\x30\x10\xfe\xe1\xfe\x43\x03\x0c\x0f\xfa\x2e\xe4\x8a\x70\xa1\x20\x9b\x61\xc6\x7c"
  for chunk in [1, 7, 4096] {
    let mut at = 0
    let budget = Budget::{ remaining: plain.length().to_int64(), emitted: 0L, }
    let reader = StreamReader::new(
      packed.length(),
      fn() {
        let n = Int32::min(chunk, packed.length() - at)
        let value = packed[at:at + n].to_owned()
        at += n
        value
      },
      plain.length(),
      budget,
    )
    let out : Array[Byte] = []
    while true {
      let data = reader.read(31)
      assert_true(reader.plain.length() <= 100000)
      if data.length() == 0 {
        break
      }
      for b in data {
        out.push(b)
      }
    }
    assert_true(reader.plain.length() <= 100000)
    assert_eq(Bytes::from_array(out), plain)
    assert_eq(budget.remaining, 0L)
    assert_eq(reader.read(1), b"")
  }
  for
    corrupt in [
      packed[:packed.length() - 1].to_owned(),
      packed + b"x",
      packed + packed,
    ] {
    let mut at = 0
    let reader = StreamReader::new(
      corrupt.length(),
      fn() {
        let n = Int32::min(7, corrupt.length() - at)
        let b = corrupt[at:at + n].to_owned()
        at += n
        b
      },
      plain.length(),
      Budget::{ remaining: plain.length().to_int64(), emitted: 0L, },
    )
    let mut failed = false
    try {
      while reader.read(31).length() != 0 {

      }
    } catch {
      _ => failed = true
    }
    assert_true(failed)
  }
  // Partial-prefix pull on a block <= 4096 RLE bytes succeeds up to the exact
  // budget and fails closed on the next byte.
  let small_writer = Writer::new(level=1)
  let small_packed = small_writer.push(
      (b"ABCD\x00\xff" + Bytes::make(256, 0x5a))[:],
    ) +
    small_writer.finish()
  let mut at = 0
  let budget = Budget::{ remaining: 6L, emitted: 0L, }
  let reader = StreamReader::new(
    small_packed.length(),
    fn() {
      let n = Int32::min(4096, small_packed.length() - at)
      let b = small_packed[at:at + n].to_owned()
      at += n
      b
    },
    262,
    budget,
  )
  assert_eq(reader.read(6), b"ABCD\x00\xff")
  let mut limited = false
  try reader.read(1) |> ignore catch {
    Limit(field="decompressed_remaining", ..) => limited = true
    _ => ()
  }
  assert_true(limited)
  assert_eq(budget.emitted, 6L)

  // Block > 4096 RLE bytes under tight budget must abort inside MTF BEFORE
  // inverse-BWT (never allocating the full RLE/BWT block).
  let mut at_over = 0
  let over_budget = Budget::{ remaining: 6L, emitted: 0L, }
  let over_reader = StreamReader::new(
    packed.length(),
    fn() {
      let n = Int32::min(4096, packed.length() - at_over)
      let b = packed[at_over:at_over + n].to_owned()
      at_over += n
      b
    },
    plain.length(),
    over_budget,
  )
  let mut over_limited = false
  try over_reader.read(6) |> ignore catch {
    Limit(field="decompressed_remaining", value~, limit=6L) =>
      over_limited = value > 4096L
    _ => ()
  }
  assert_true(over_limited)
  assert_eq(over_reader.plain.length(), 0)
  assert_false(over_reader.in_block)
  assert_true(over_reader.failed)
  assert_eq(over_budget.emitted, 0L)
}

///|
test "stream pull: fault latch and zero-remaining block bound" {
  // Truncated stream delivered across two chunks: first read fails Truncated,
  // second read must stay latched as Parameter without replaying buffered data.
  let truncated = b"BZh91AY&SY"
  let chunks = [truncated[:5].to_owned(), truncated[5:].to_owned()]
  let mut chunk_index = 0
  let mut source_calls = 0
  let trunc_reader = StreamReader::new(
    truncated.length(),
    fn() {
      source_calls += 1
      if chunk_index < chunks.length() {
        let part = chunks[chunk_index]
        chunk_index += 1
        part
      } else {
        b""
      }
    },
    16,
    Budget::{ remaining: 16L, emitted: 0L, },
  )
  let mut saw_truncated = false
  try trunc_reader.read(1) |> ignore catch {
    Truncated(at=10) => saw_truncated = true
    _ => ()
  }
  assert_true(saw_truncated)
  assert_true(trunc_reader.failed)
  let calls_after_fault = source_calls
  let mut saw_parameter = false
  try trunc_reader.read(1) |> ignore catch {
    Parameter => saw_parameter = true
    _ => ()
  }
  assert_true(saw_parameter)
  assert_eq(source_calls, calls_after_fault)

  // Single-block stream with 4352 distinct adjacent bytes (> 4096 RLE bytes).
  let writer = Writer::new(level=1)
  let packed = writer.push(
      Bytes::from_array(Array::makei(4352, i => (i % 256).to_byte()))[:],
    ) +
    writer.finish()

  // Zero cap must fail before decoding the block.
  let mut at_cap = 0
  let cap_budget = Budget::{ remaining: 100L, emitted: 0L, }
  let cap_reader = StreamReader::new(
    packed.length(),
    fn() {
      let n = Int32::min(4096, packed.length() - at_cap)
      let part = packed[at_cap:at_cap + n].to_owned()
      at_cap += n
      part
    },
    0,
    cap_budget,
  )
  let mut saw_cap_limit = false
  try cap_reader.read(1) |> ignore catch {
    Limit(field="block_output_bytes", value=1L, limit=0L) =>
      saw_cap_limit = true
    _ => ()
  }
  assert_true(saw_cap_limit)
  assert_eq(cap_reader.plain.length(), 0)
  assert_false(cap_reader.in_block)
  assert_true(cap_reader.failed)
  assert_eq(cap_budget.emitted, 0L)

  // Zero remaining shared budget must also fail before decoding the block.
  let mut at_rem = 0
  let zero_budget = Budget::{ remaining: 0L, emitted: 0L, }
  let rem_reader = StreamReader::new(
    packed.length(),
    fn() {
      let n = Int32::min(4096, packed.length() - at_rem)
      let part = packed[at_rem:at_rem + n].to_owned()
      at_rem += n
      part
    },
    100,
    zero_budget,
  )
  let mut saw_rem_limit = false
  try rem_reader.read(1) |> ignore catch {
    Limit(field="decompressed_remaining", value=1L, limit=0L) =>
      saw_rem_limit = true
    _ => ()
  }
  assert_true(saw_rem_limit)
  assert_eq(rem_reader.plain.length(), 0)
  assert_false(rem_reader.in_block)
  assert_true(rem_reader.failed)
  assert_eq(zero_budget.emitted, 0L)

  // One-shot decode rejects > 4096 RLE bytes early without decoding the block.
  let one_budget = Budget::{ remaining: 1L, emitted: 0L, }
  let mut saw_decode_cap_limit = false
  try decode(packed[:], 1, one_budget) |> ignore catch {
    Limit(field="block_output_bytes", value~, limit=1L) =>
      saw_decode_cap_limit = value > 4096L
    _ => ()
  }
  assert_true(saw_decode_cap_limit)
  assert_eq(one_budget.emitted, 0L)

  let rem_only_budget = Budget::{ remaining: 1L, emitted: 0L, }
  let mut saw_decode_rem_limit = false
  try decode(packed[:], 100000, rem_only_budget) |> ignore catch {
    Limit(field="decompressed_remaining", value~, limit=1L) =>
      saw_decode_rem_limit = value > 4096L
    _ => ()
  }
  assert_true(saw_decode_rem_limit)
  assert_eq(rem_only_budget.emitted, 0L)

  // 45-byte BZh9 BWT bomb (898,000 alternating \x00\x01 bytes): StreamReader
  // must reject before inverse-BWT under tight cap or budget, never filling `plain`.
  let bwt_bomb = b"\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x76\x31\xc6\x35\x03\x6c\xf3\xc0\x00\x60\x00\x20\x00\x30\x80\x4d\x46\xa9\x05\x11\x35\x48\x28\x89\xc5\xdc\x91\x4e\x14\x24\x1d\x8c\x71\x8d\x40"
  let mut at_bomb_cap = 0
  let bomb_cap_budget = Budget::{ remaining: 100000L, emitted: 0L, }
  let bomb_cap_reader = StreamReader::new(
    bwt_bomb.length(),
    fn() {
      let n = Int32::min(4096, bwt_bomb.length() - at_bomb_cap)
      let part = bwt_bomb[at_bomb_cap:at_bomb_cap + n].to_owned()
      at_bomb_cap += n
      part
    },
    1,
    bomb_cap_budget,
  )
  let mut saw_bomb_cap = false
  try bomb_cap_reader.read(1) |> ignore catch {
    Limit(field="block_output_bytes", value~, limit=1L) =>
      saw_bomb_cap = value > 4096L
    _ => ()
  }
  assert_true(saw_bomb_cap)
  assert_eq(bomb_cap_reader.plain.length(), 0)
  assert_false(bomb_cap_reader.in_block)
  assert_true(bomb_cap_reader.failed)
  assert_eq(bomb_cap_budget.emitted, 0L)

  let mut at_bomb_rem = 0
  let bomb_rem_budget = Budget::{ remaining: 1L, emitted: 0L, }
  let bomb_rem_reader = StreamReader::new(
    bwt_bomb.length(),
    fn() {
      let n = Int32::min(4096, bwt_bomb.length() - at_bomb_rem)
      let part = bwt_bomb[at_bomb_rem:at_bomb_rem + n].to_owned()
      at_bomb_rem += n
      part
    },
    100000,
    bomb_rem_budget,
  )
  let mut saw_bomb_rem = false
  try bomb_rem_reader.read(1) |> ignore catch {
    Limit(field="decompressed_remaining", value~, limit=1L) =>
      saw_bomb_rem = value > 4096L
    _ => ()
  }
  assert_true(saw_bomb_rem)
  assert_eq(bomb_rem_reader.plain.length(), 0)
  assert_false(bomb_rem_reader.in_block)
  assert_true(bomb_rem_reader.failed)
  assert_eq(bomb_rem_budget.emitted, 0L)
}
