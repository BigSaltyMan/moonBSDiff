///|
fn resource_error(
  result : Result[Bytes, BsdiffError],
  kind : ErrorKind,
  stage : ErrorStage,
  field : String,
  value : Int64,
  limit : Int64,
) -> Unit raise {
  match result {
    Ok(_) => abort("resource failure returned a patch")
    Err(e) => {
      assert_eq(e.kind, kind)
      assert_eq(e.stage, stage)
      assert_eq(e.field, Some(field))
      assert_eq(e.value, Some(value))
      assert_eq(e.limit, Some(limit))
      assert_eq(e.block, None)
      assert_eq(e.offset, None)
    }
  }
}

///|
test "diff-resource-compact-exact-cumulative-work" {
  let limits = Limits::for_diff()
  let sort = suffix_test_budget(limits.max_sort_work)
  let work = matching_test_budget(limits.max_match_work)
  let patch = match generate_patch(b"A", b"A", limits, sort, work) {
    Ok(v) => v
    Err(_) => abort("counted call failed")
  }
  // N=2: initialization 4N+257, then 5N+4*257 = 1303.
  assert_eq(limits.max_sort_work - sort.remaining, 1303L)
  // Scan 10 + plan validation 1 + encode (4*25+1), five writer
  // feed/finish visits, two copies per compressed byte, final three passes.
  let exact_work = 53L + 5L * patch.length().to_int64()
  assert_eq(limits.max_match_work - work.remaining, exact_work)
  let exact = { ..limits, max_sort_work: 1303L, max_match_work: exact_work, }
  assert_eq(diff(b"A", b"A", exact), Ok(patch))
  resource_error(
    diff(b"A", b"A", { ..exact, max_sort_work: 1302L, }),
    ResourceLimitExceeded,
    Sorting,
    "sort_remaining",
    1038L,
    1037L,
  )
  // One byte-visit short fails in final assembly, not in scanning. No reset.
  resource_error(
    diff(b"A", b"A", { ..exact, max_match_work: exact_work - 1L, }),
    ResourceLimitExceeded,
    Matching,
    "match_remaining",
    3L * patch.length().to_int64(),
    3L * patch.length().to_int64() - 1L,
  )
  assert_eq(diff(b"A", b"A", exact), Ok(patch))
}

///|
test "diff-resource-compact-raw-and-compressed-quotas" {
  let limits = Limits::for_diff()
  let patch = match diff(b"A", b"A", limits) {
    Ok(v) => v
    Err(_) => abort("fixture failed")
  }
  for (field, cap) in [("old", 1L), ("new", 1L), ("output", 1L)] {
    let exact = match field {
      "old" => { ..limits, max_old_bytes: cap, }
      "new" => { ..limits, max_new_bytes: cap, }
      _ => { ..limits, max_output_bytes: cap, }
    }
    assert_eq(diff(b"A", b"A", exact), Ok(patch))
  }
  for
    (bad, field) in [
      ({ ..limits, max_old_bytes: 1L, }, "max_old_bytes"),
      ({ ..limits, max_new_bytes: 1L, }, "max_new_bytes"),
      ({ ..limits, max_output_bytes: 1L, }, "max_output_bytes"),
    ] {
    resource_error(
      diff(b"AB", b"AB", bad),
      ResourceLimitExceeded,
      Header,
      field,
      2L,
      1L,
    )
    assert_eq(diff(b"A", b"A", limits), Ok(patch))
  }
  assert_eq(
    diff(b"A", b"A", {
      ..limits,
      max_control_instructions: 1L,
      max_decompressed_bytes: 25L,
    }),
    Ok(patch),
  )
  resource_error(
    diff(b"A", b"A", { ..limits, max_decompressed_bytes: 24L, }),
    ResourceLimitExceeded,
    Control,
    "max_decompressed_bytes",
    25L,
    24L,
  )
  let size = patch.length().to_int64()
  assert_eq(diff(b"A", b"A", { ..limits, max_patch_bytes: size, }), Ok(patch))
  resource_error(
    diff(b"A", b"A", { ..limits, max_patch_bytes: size - 1L, }),
    ResourceLimitExceeded,
    Header,
    "max_patch_bytes",
    size,
    size - 1L,
  )
  // One shared quota for three empty streams, including the 32-byte header.
  let quota = PatchBudget::{ used: 32L, limit: 73L, }
  let work = matching_test_budget(10000L)
  assert_eq(
    compress_generation_block(b"", quota, work),
    Ok(b"BZh9\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"),
  )
  assert_true(compress_generation_block(b"", quota, work) is Ok(_))
  resource_error(
    compress_generation_block(b"", quota, work),
    ResourceLimitExceeded,
    Header,
    "max_patch_bytes",
    74L,
    73L,
  )
  assert_eq(quota.used, 60L)
  assert_eq(
    diff(b"", b"", { ..limits, max_patch_bytes: 74L, }),
    Ok(
      b"BSDIFF40" +
      b"\x0e\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" +
      b"BZh9\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00" +
      b"BZh9\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00" +
      b"BZh9\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00",
    ),
  )
}

///|
test "diff-resource-compact-preflight-and-overflow" {
  let limits = Limits::for_diff()
  let sort = suffix_test_budget(0L)
  let work = matching_test_budget(0L)
  resource_error(
    generate_patch(b"AB", b"A", { ..limits, max_old_bytes: 1L, }, sort, work),
    ResourceLimitExceeded,
    Header,
    "max_old_bytes",
    2L,
    1L,
  )
  assert_eq(sort.remaining, 0L)
  assert_eq(work.remaining, 0L)
  resource_error(
    generate_patch(
      b"A",
      b"A",
      { ..limits, max_decompressed_bytes: 24L, },
      sort,
      work,
    ),
    ResourceLimitExceeded,
    Control,
    "max_decompressed_bytes",
    25L,
    24L,
  )
  assert_eq(sort.remaining, 0L)
  assert_eq(work.remaining, 0L)
  let sort = suffix_test_budget(9223372036854775807L)
  assert_eq(
    sort.reserve(-1L),
    Err(sorting_error(InvalidConfiguration, "sort_reservation", -1L, Some(0L))),
  )
  assert_eq(sort.remaining, 9223372036854775807L)
  let work = matching_test_budget(9223372036854775807L)
  assert_eq(
    work.reserve(-1L),
    Err(
      matching_error(
        InvalidConfiguration,
        "match_reservation",
        Some(-1L),
        Some(9223372036854775807L),
      ),
    ),
  )
  assert_eq(work.remaining, 9223372036854775807L)
  assert_eq(work.reserve(9223372036854775807L), Ok(()))
  assert_eq(
    work.reserve(1L),
    Err(
      matching_error(
        ResourceLimitExceeded,
        "match_remaining",
        Some(1L),
        Some(0L),
      ),
    ),
  )
  // Existing pure preflights reject platform/count overflow without allocation.
  assert_eq(
    raw_control_size(9223372036854775807L, 0L, 0L, 9223372036854775807L),
    Err(
      generation_error(
        IntegerOverflow,
        Control,
        "control_bytes",
        9223372036854775807L,
        Some(2147483647L / 24L),
      ),
    ),
  )
  assert_eq(
    suffix_sizes(2147483647L, 2147483647L),
    Err(
      sorting_error(
        IntegerOverflow,
        "suffix_length",
        2147483647L,
        Some(2147483646L),
      ),
    ),
  )
}

///|
test "diff-resource-native-writer-block-boundary" {
  let raw = Bytes::from_array(Array::makei(900010, i => (i % 251).to_byte()))
  let quota = PatchBudget::{ used: 32L, limit: 10000L, }
  let encoded = match
    compress_generation_block(raw, quota, matching_test_budget(1000000L)) {
    Ok(v) => v
    Err(_) => abort("bounded writer failed")
  }
  assert_eq(quota.used, 32L + encoded.length().to_int64())
  let limits = { ..Limits::for_diff(), max_decompressed_bytes: 900010L, }
  let budget = match decompression_budget(limits) {
    Ok(v) => v
    Err(_) => abort("decode budget")
  }
  assert_eq(decompress_block(encoded, 900010L, budget, Extra, 0L), Ok(raw))
  let text = StringBuilder()
  let digits = b"0123456789abcdef"
  for b in encoded {
    text.write_char(digits[b.to_int() / 16].to_int().to_char().unwrap())
    text.write_char(digits[b.to_int() % 16].to_int().to_char().unwrap())
  }
  println("GENSTREAM:" + text.to_string())
}

///|
test "diff-resource-compact-plan-growth-before-allocation" {
  let limits = Limits::for_diff()
  let a = Bytes::from_array(Array::make(32, b'A'))
  let b = Bytes::from_array(Array::make(32, b'B'))
  let old = a + b
  let new = b + a
  // Initial zero-output seek, B span, then A span: three control triples.
  let exact = {
    ..limits,
    max_control_instructions: 3L,
    max_decompressed_bytes: 136L,
  }
  let patch = match diff(old, new, exact) {
    Ok(v) => v
    Err(_) => abort("exact plan cap failed")
  }
  assert_eq(apply(old, patch, exact), Ok(new))
  resource_error(
    diff(old, new, { ..exact, max_control_instructions: 2L, }),
    ResourceLimitExceeded,
    Matching,
    "segments",
    3L,
    2L,
  )
  resource_error(
    diff(old, new, { ..exact, max_decompressed_bytes: 135L, }),
    ResourceLimitExceeded,
    Control,
    "max_decompressed_bytes",
    136L,
    135L,
  )
  assert_eq(diff(old, new, exact), Ok(patch))
}
