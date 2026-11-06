///|
fn compression_body(kind : Int32, length~ : Int32 = 0) -> Bytes {
  match kind {
    0 => b""
    1 => b"BSDIFF40\x00\xff\x01\x80"
    2 => Bytes::from_array(Array::makei(256, i => i.to_byte()))
    3 => Bytes::from_array(Array::make(4096, b'A'))
    _ => Bytes::from_array(Array::makei(length, i => (i % 256).to_byte()))
  }
}

///|
fn compression_budget(n : Int64) -> @bounded.Budget {
  @bounded.Budget::{ remaining: n, emitted: 0L, }
}

///|
fn compression_error(
  data : Bytes,
  kind : ErrorKind,
  stage : ErrorStage,
  field : String?,
) -> BsdiffError {
  match decompress_block(data, 20000L, compression_budget(20000L), stage, 32L) {
    Ok(_) => abort("expected compression failure")
    Err(e) => {
      try! assert_eq(e.kind, kind)
      try! assert_eq(e.stage, stage)
      try! assert_eq(
        e.block,
        Some(
          match stage {
            Control => "control"
            Diff => "diff"
            _ => "extra"
          },
        ),
      )
      if field is Some(_) {
        try! assert_eq(e.field, field)
      }
      e
    }
  }
}

///|
fn compression_emit(name : String, packed : Bytes) -> Unit {
  let digits = b"0123456789abcdef"
  let text = StringBuilder()
  for b in packed {
    text.write_char(digits[b.to_int() / 16].to_int().to_char().unwrap())
    text.write_char(digits[b.to_int() % 16].to_int().to_char().unwrap())
  }
  println("COMPRESSION:\{name}:\{text.to_string()}")
}

///|
test "compression-compact-independent-levels-and-encoding" {
  let fixtures = [
    (0, compression_fixture_empty_1(), compression_fixture_empty_9()),
    (1, compression_fixture_binary_1(), compression_fixture_binary_9()),
    (2, compression_fixture_all_1(), compression_fixture_all_9()),
    (3, compression_fixture_repeat_1(), compression_fixture_repeat_9()),
  ]
  for (kind, low, high) in fixtures {
    let plain = compression_body(kind)
    for packed in [low, high] {
      let snapshot = packed.to_array()
      let budget = compression_budget(plain.length().to_int64())
      assert_eq(
        decompress_block(
          packed,
          plain.length().to_int64(),
          budget,
          Control,
          32L,
        ),
        Ok(plain),
      )
      assert_eq(budget.remaining, 0L)
      assert_eq(packed.to_array(), snapshot)
    }
    let snapshot = plain.to_array()
    let packed = compress_block(plain)
    assert_eq(packed[0:4].to_owned(), b"BZh9")
    assert_eq(plain.to_array(), snapshot)
    compression_emit(["empty", "binary", "all", "repeat"][kind], packed)
  }
}

///|
test "compression-compact-truncation-crcs-and-single-stream" {
  let packed = compression_fixture_binary_9()
  // Every proper prefix of a valid stream is truncated, including its final CRC.
  for n in 0..<packed.length() {
    let e = compression_error(packed[0:n].to_owned(), TruncatedData, Diff, None)
    assert_true(e.offset is Some(_))
  }
  let wrong = packed.to_array()
  wrong[3] = b'0'
  let e = compression_error(Bytes::from_array(wrong), InvalidField, Extra, None)
  assert_eq(e.offset, Some(35L))
  wrong[3] = b'9'
  wrong[10] = (wrong[10].to_int() ^ 1).to_byte()
  let e = compression_error(
    Bytes::from_array(wrong),
    DecompressionFailed,
    Control,
    Some("crc"),
  )
  assert_eq(e.offset, None)
  let wrong_stream = packed.to_array()
  // Flipping the high bit of the last byte alters combined CRC (not padding).
  let last = wrong_stream.length() - 1
  wrong_stream[last] = (wrong_stream[last].to_int() ^ 128).to_byte()
  let e = compression_error(
    Bytes::from_array(wrong_stream),
    DecompressionFailed,
    Extra,
    Some("crc"),
  )
  assert_eq(e.offset, None)
  for stream in [packed, compression_fixture_empty_9()] {
    for tail in [b"x", compression_fixture_empty_1(), packed] {
      let e = compression_error(stream + tail, InvalidField, Diff, None)
      assert_eq(e.offset, Some(32L + stream.length().to_int64()))
    }
  }
  // The same level-1 encoded small block is valid under all larger block ceilings.
  for level in 1..<=9 {
    let bytes = compression_fixture_binary_1().to_array()
    bytes[3] = (48 + level).to_byte()
    assert_eq(
      decompress_block(
        Bytes::from_array(bytes),
        12L,
        compression_budget(12L),
        Control,
        0L,
      ),
      Ok(compression_body(1)),
    )
  }
  let e = compression_error(b"XZh9", InvalidField, Control, None)
  assert_eq(e.offset, Some(32L))
}

///|
test "compression-compact-pre-expansion-budgets-and-reuse" {
  let from_limits = decompression_budget(test_limits())
  guard from_limits is Ok(from_limits) else { abort("expected valid limits") }
  assert_eq(from_limits.remaining, 1024L)
  let invalid = { ..test_limits(), max_decompressed_bytes: 0L, }
  guard decompression_budget(invalid) is Err(e) else {
    abort("expected invalid limits")
  }
  assert_eq(e.stage, Configuration)
  let packed = compression_fixture_repeat_9()
  let budget = compression_budget(4095L)
  let result = decompress_block(packed, 4096L, budget, Extra, 32L)
  guard result is Err(e) else { abort("expected budget error") }
  assert_eq(e.kind, ResourceLimitExceeded)
  assert_eq(e.stage, Extra)
  assert_eq(e.block, Some("extra"))
  assert_eq(e.field, Some("decompressed_remaining"))
  assert_true(budget.emitted <= 4095L)
  assert_eq(budget.remaining + budget.emitted, 4095L)
  assert_true(e.value.unwrap() > e.limit.unwrap())
  let budget = compression_budget(5000L)
  guard decompress_block(packed, 4095L, budget, Diff, 0L) is Err(e) else {
    abort("expected cap error")
  }
  assert_eq(e.field, Some("block_output_bytes"))
  assert_true(budget.emitted <= 4095L)
  assert_eq(
    decompress_block(packed, 4096L, compression_budget(4096L), Control, 32L),
    Ok(compression_body(3)),
  )
  let shared = compression_budget(24L)
  let small = compression_fixture_binary_9()
  for stage in [Control, Diff] {
    assert_eq(
      decompress_block(small, 12L, shared, stage, 0L),
      Ok(compression_body(1)),
    )
  }
  assert_eq(shared.remaining, 0L)
  assert_eq(
    decompress_block(compression_fixture_empty_9(), 0L, shared, Extra, 0L),
    Ok(b""),
  )
  guard decompress_block(small, 12L, shared, Extra, 0L) is Err(e) else {
    abort("expected shared budget error")
  }
  assert_eq(e.kind, ResourceLimitExceeded)
  assert_eq(shared.emitted, 24L)
  let exact = compression_budget(36L)
  for stage in [Control, Diff, Extra] {
    assert_eq(
      decompress_block(small, 12L, exact, stage, 0L),
      Ok(compression_body(1)),
    )
  }
  assert_eq(exact.remaining, 0L)
  guard decompress_block(small, 0L, compression_budget(20L), Control, 0L)
    is Err(e) else {
    abort("expected zero cap")
  }
  assert_eq(e.kind, ResourceLimitExceeded)
  guard decompress_block(small, -1L, compression_budget(20L), Control, 0L)
    is Err(e) else {
    abort("expected invalid cap")
  }
  assert_eq(e.kind, InvalidConfiguration)
  guard decompress_block(small, 12L, compression_budget(-1L), Control, 0L)
    is Err(e) else {
    abort("expected invalid budget")
  }
  assert_eq(e.kind, InvalidConfiguration)
  guard decompress_block(
      small,
      2147483648L,
      compression_budget(20L),
      Control,
      0L,
    )
    is Err(e) else {
    abort("expected index cap")
  }
  assert_eq(e.kind, InvalidConfiguration)
  guard decompress_block(
      small,
      12L,
      compression_budget(20L),
      Control,
      9223372036854775807L,
    )
    is Err(e) else {
    abort("expected offset overflow")
  }
  assert_eq(e.kind, IntegerOverflow)
}

///|
test "compression-compact-logical-position-and-padding" {
  let packed = compression_fixture_binary_9()
  let decoded = @bounded.decode(packed[:], 12, compression_budget(12L))
  assert_eq((decoded.consumed_bits + 7L) / 8L, packed.length().to_int64())
  assert_eq(decoded.blocks, 1)
  let padding = (packed.length().to_int64() * 8L - decoded.consumed_bits).to_int()
  assert_true(padding > 0 && padding < 8)
  let changed = packed.to_array()
  let last = changed.length() - 1
  changed[last] = (changed[last].to_int() | ((1 << padding) - 1)).to_byte()
  // No invented zero-padding requirement: only additional full bytes are rejected.
  assert_eq(
    decompress_block(
      Bytes::from_array(changed),
      12L,
      compression_budget(12L),
      Control,
      0L,
    ),
    Ok(compression_body(1)),
  )
}

///|
test "compression-large-boundaries-native" {
  for
    (packed, length, count) in [
      (compression_fixture_near1_1(), 99980, 1),
      (compression_fixture_cross1_1(), 110080, 2),
      (compression_fixture_near9_9(), 899980, 1),
      (compression_fixture_cross9_9(), 921600, 2),
    ] {
    let decoded = @bounded.decode(
      packed[:],
      length,
      compression_budget(length.to_int64()),
    )
    assert_eq(decoded.output, compression_body(4, length~))
    assert_eq(decoded.blocks, count)
  }
  let large = compression_body(4, length=921600)
  compression_emit("cross9", compress_block(large))
}

///|
test "compression-dependency-gaps-native" {
  let stream = compression_fixture_binary_1()
  // A successful public one-shot decode does not imply complete input consumption.
  assert_eq(@bzip2.bunzip2((stream + b"garbage")[:]), compression_body(1))
  let reader = @bzip2.Reader::new(limit=100000)
  let input = compression_fixture_cross1_1()
  let mut total = 0
  let mut at = 0
  while at < input.length() {
    let end = if at + 100 < input.length() { at + 100 } else { input.length() }
    total += reader.push(input[at:end]).length()
    at = end
  }
  total += reader.finish().length()
  assert_eq(total, 110080)
  println(
    "DEPENDENCY-GAPS: public bunzip2 accepted trailing data; Reader push total=110080 with limit=100000",
  )
}
