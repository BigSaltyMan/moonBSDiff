///|
fn fastpath_random(length : Int32, seed : UInt32) -> Bytes {
  let mut state = seed
  let bytes : Array[Byte] = []
  for _ in 0..<length {
    state = state * 1664525U + 1013904223U
    bytes.push((state >> 24).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
fn fastpath_stream_apply(
  old : Bytes,
  patch : Bytes,
  limits : @moonbsdiff.Limits,
) -> Result[
  (Bytes, @moonbsdiff.DeepPatchInfo),
  @moonbsdiff.StreamApplyError[Unit],
] {
  let out : Array[Byte] = []
  match
    @moonbsdiff.apply_stream(
      old.length().to_int64(),
      patch.length().to_int64(),
      limits,
      read_old_at=(offset, count) => {
        let start = offset.to_int()
        let end = Int32::min(old.length(), start + count)
        Ok(old[start:end].to_owned())
      },
      read_patch_at=(offset, count) => {
        let start = offset.to_int()
        let end = Int32::min(patch.length(), start + count)
        Ok(patch[start:end].to_owned())
      },
      write_output=chunk => {
        for b in chunk {
          out.push(b)
        }
        Ok(())
      },
    ) {
    Ok(info) => Ok((Bytes::from_array(out), info))
    Err(e) => Err(e)
  }
}

///|
fn fastpath_assert_err(
  result : Result[Bytes, @moonbsdiff.BsdiffError],
  kind : @moonbsdiff.ErrorKind,
  stage : @moonbsdiff.ErrorStage,
  field : String,
) -> Unit raise {
  match result {
    Ok(_) => abort("expected diff failure")
    Err(e) => {
      assert_eq(e.kind, kind)
      assert_eq(e.stage, stage)
      assert_eq(e.field, Some(field))
    }
  }
}

///|
test "diff-fastpath-threshold-63-vs-64" {
  let limits = @moonbsdiff.Limits::for_diff()
  let zero_sort = { ..limits, max_sort_work: 1L, }

  let block63 = fastpath_random(63, 1001U)
  fastpath_assert_err(
    @moonbsdiff.diff(block63, block63, zero_sort),
    ResourceLimitExceeded,
    Sorting,
    "sort_remaining",
  )
  let block64 = fastpath_random(64, 1002U)
  let ok64 = @moonbsdiff.diff(block64, block64, zero_sort).unwrap()
  assert_eq(@moonbsdiff.apply(block64, ok64, limits), Ok(block64))

  let pre31 = fastpath_random(31, 1003U)
  let suf32 = fastpath_random(32, 1004U)
  let ins63_old = pre31 + suf32
  let ins63_new = pre31 + b"X" + suf32
  fastpath_assert_err(
    @moonbsdiff.diff(ins63_old, ins63_new, zero_sort),
    ResourceLimitExceeded,
    Sorting,
    "sort_remaining",
  )
  fastpath_assert_err(
    @moonbsdiff.diff(ins63_new, ins63_old, zero_sort),
    ResourceLimitExceeded,
    Sorting,
    "sort_remaining",
  )

  let pre32 = fastpath_random(32, 1005U)
  let ins64_old = pre32 + suf32
  let ins64_new = pre32 + b"X" + suf32
  let p_ins = @moonbsdiff.diff(ins64_old, ins64_new, zero_sort).unwrap()
  let p_del = @moonbsdiff.diff(ins64_new, ins64_old, zero_sort).unwrap()
  assert_eq(@moonbsdiff.apply(ins64_old, p_ins, limits), Ok(ins64_new))
  assert_eq(@moonbsdiff.apply(ins64_new, p_del, limits), Ok(ins64_old))
}

///|
test "diff-fastpath-case1-identical-and-index-parity" {
  let limits = @moonbsdiff.Limits::for_diff()
  let zero_sort = { ..limits, max_sort_work: 1L, }
  for size in [64, 128, 4096] {
    let data = fastpath_random(size, 2000U + size.reinterpret_as_uint())
    let patch = @moonbsdiff.diff(data, data, zero_sort).unwrap()
    let info = @moonbsdiff.inspect_deep(patch, limits).unwrap()
    assert_eq(info.control_count, 1L)
    assert_eq(info.diff_bytes, size.to_int64())
    assert_eq(info.extra_bytes, 0L)
    assert_eq(@moonbsdiff.apply(data, patch, limits), Ok(data))
    assert_eq(fastpath_stream_apply(data, patch, limits), Ok((data, info)))

    let index = @moonbsdiff.DiffIndex::build(data, limits).unwrap()
    assert_eq(index.diff(data, zero_sort), Ok(patch))

    let exact_raw = 24L + size.to_int64()
    assert_eq(
      @moonbsdiff.diff(data, data, {
        ..zero_sort,
        max_decompressed_bytes: exact_raw,
      }),
      Ok(patch),
    )
    fastpath_assert_err(
      @moonbsdiff.diff(data, data, {
        ..zero_sort,
        max_decompressed_bytes: exact_raw - 1L,
      }),
      ResourceLimitExceeded,
      Control,
      "max_decompressed_bytes",
    )
  }
}

///|
test "diff-fastpath-case2-pure-insert" {
  let limits = @moonbsdiff.Limits::for_diff()
  let zero_sort = { ..limits, max_sort_work: 1L, }

  // Subcase s == 0: pure append after 64-byte prefix.
  let p64 = fastpath_random(64, 3001U)
  let app_mid = fastpath_random(19, 3002U)
  let new_app = p64 + app_mid
  let patch_app = @moonbsdiff.diff(p64, new_app, zero_sort).unwrap()
  let info_app = @moonbsdiff.inspect_deep(patch_app, limits).unwrap()
  assert_eq(info_app.control_count, 1L)
  assert_eq(info_app.diff_bytes, 64L)
  assert_eq(info_app.extra_bytes, 19L)
  assert_eq(@moonbsdiff.apply(p64, patch_app, limits), Ok(new_app))
  assert_eq(
    fastpath_stream_apply(p64, patch_app, limits),
    Ok((new_app, info_app)),
  )
  let idx_app = @moonbsdiff.DiffIndex::build(p64, limits).unwrap()
  let idx_patch_app = idx_app.diff(new_app, zero_sort).unwrap()
  assert_eq(@moonbsdiff.apply(p64, idx_patch_app, limits), Ok(new_app))

  // Subcase s > 0: prepend (p == 0, s >= 64) and middle insert (p > 0, s > 0).
  for
    pair in [
      (b"", fastpath_random(64, 3003U), fastpath_random(11, 3004U)),
      (
        fastpath_random(32, 3005U),
        fastpath_random(32, 3006U),
        fastpath_random(17, 3007U),
      ),
      (
        fastpath_random(100, 3008U),
        fastpath_random(200, 3009U),
        fastpath_random(25, 3010U),
      ),
    ] {
    let (pre, suf, ins) = pair
    let old = pre + suf
    let new = pre + ins + suf
    let patch = @moonbsdiff.diff(old, new, zero_sort).unwrap()
    let info = @moonbsdiff.inspect_deep(patch, limits).unwrap()
    assert_eq(info.control_count, 2L)
    assert_eq(info.diff_bytes, old.length().to_int64())
    assert_eq(info.extra_bytes, ins.length().to_int64())
    assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
    assert_eq(fastpath_stream_apply(old, patch, limits), Ok((new, info)))
    let index = @moonbsdiff.DiffIndex::build(old, limits).unwrap()
    let idx_patch = index.diff(new, zero_sort).unwrap()
    assert_eq(@moonbsdiff.apply(old, idx_patch, limits), Ok(new))

    fastpath_assert_err(
      @moonbsdiff.diff(old, new, { ..zero_sort, max_control_instructions: 1L, }),
      ResourceLimitExceeded,
      Matching,
      "segments",
    )
    fastpath_assert_err(
      index.diff(new, { ..zero_sort, max_control_instructions: 1L, }),
      ResourceLimitExceeded,
      Matching,
      "segments",
    )
    let exact_raw = 48L + new.length().to_int64()
    assert_eq(
      @moonbsdiff.diff(old, new, {
        ..zero_sort,
        max_decompressed_bytes: exact_raw,
      }),
      Ok(patch),
    )
    fastpath_assert_err(
      @moonbsdiff.diff(old, new, {
        ..zero_sort,
        max_decompressed_bytes: exact_raw - 1L,
      }),
      ResourceLimitExceeded,
      Control,
      "max_decompressed_bytes",
    )
  }
}

///|
test "diff-fastpath-case3-pure-delete" {
  let limits = @moonbsdiff.Limits::for_diff()
  let zero_sort = { ..limits, max_sort_work: 1L, }

  // Subcase s == 0: pure truncate leaving 64 bytes.
  let p64 = fastpath_random(64, 4001U)
  let old_trunc = p64 + fastpath_random(20, 4002U)
  let patch_trunc = @moonbsdiff.diff(old_trunc, p64, zero_sort).unwrap()
  let info_trunc = @moonbsdiff.inspect_deep(patch_trunc, limits).unwrap()
  assert_eq(info_trunc.control_count, 1L)
  assert_eq(info_trunc.diff_bytes, 64L)
  assert_eq(info_trunc.extra_bytes, 0L)
  assert_eq(@moonbsdiff.apply(old_trunc, patch_trunc, limits), Ok(p64))
  assert_eq(
    fastpath_stream_apply(old_trunc, patch_trunc, limits),
    Ok((p64, info_trunc)),
  )
  let idx_trunc = @moonbsdiff.DiffIndex::build(old_trunc, limits).unwrap()
  assert_eq(idx_trunc.diff(p64, zero_sort), Ok(patch_trunc))

  // Subcase s > 0: delete from front (p == 0) and delete from middle.
  for
    pair in [
      (b"", fastpath_random(64, 4003U), fastpath_random(13, 4004U)),
      (
        fastpath_random(32, 4005U),
        fastpath_random(32, 4006U),
        fastpath_random(9, 4007U),
      ),
      (
        fastpath_random(120, 4008U),
        fastpath_random(150, 4009U),
        fastpath_random(40, 4010U),
      ),
    ] {
    let (pre, suf, del) = pair
    let old = pre + del + suf
    let new = pre + suf
    let patch = @moonbsdiff.diff(old, new, zero_sort).unwrap()
    let info = @moonbsdiff.inspect_deep(patch, limits).unwrap()
    assert_eq(info.control_count, 2L)
    assert_eq(info.diff_bytes, new.length().to_int64())
    assert_eq(info.extra_bytes, 0L)
    assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
    assert_eq(fastpath_stream_apply(old, patch, limits), Ok((new, info)))
    let index = @moonbsdiff.DiffIndex::build(old, limits).unwrap()
    assert_eq(index.diff(new, zero_sort), Ok(patch))

    fastpath_assert_err(
      @moonbsdiff.diff(old, new, { ..zero_sort, max_control_instructions: 1L, }),
      ResourceLimitExceeded,
      Matching,
      "segments",
    )
    let exact_raw = 48L + new.length().to_int64()
    assert_eq(
      @moonbsdiff.diff(old, new, {
        ..zero_sort,
        max_decompressed_bytes: exact_raw,
      }),
      Ok(patch),
    )
    fastpath_assert_err(
      @moonbsdiff.diff(old, new, {
        ..zero_sort,
        max_decompressed_bytes: exact_raw - 1L,
      }),
      ResourceLimitExceeded,
      Control,
      "max_decompressed_bytes",
    )
  }
}

///|
test "diff-fastpath-case4-middle-sort-reduction-and-tail-bridge" {
  let limits = @moonbsdiff.Limits::for_diff()

  // Only the 16-byte middle is sorted instead of all 1016 bytes.
  let p500 = fastpath_random(500, 5001U)
  let s500 = fastpath_random(500, 5002U)
  let old16 = fastpath_random(16, 5003U)
  let new16 = fastpath_random(16, 5004U)
  let old_big = p500 + old16 + s500
  let new_big = p500 + new16 + s500
  let mid_only_sort = { ..limits, max_sort_work: 2000L, }
  let patch_big = @moonbsdiff.diff(old_big, new_big, mid_only_sort).unwrap()
  assert_eq(@moonbsdiff.apply(old_big, patch_big, limits), Ok(new_big))
  assert_true(
    @moonbsdiff.DiffIndex::build(old_big, mid_only_sort)
    is Err(
      {
        kind: ResourceLimitExceeded,
        stage: Sorting,
        field: Some("sort_remaining"),
        ..
      },
    ),
  )

  // Tail Bridge triggered: p = 40, s = 80, equal-length replaced middle (12 < 80).
  let p40 = fastpath_random(40, 5005U)
  let s80 = fastpath_random(80, 5006U)
  let old_mid12 = fastpath_random(12, 5007U)
  let new_mid12 = fastpath_random(12, 5008U)
  let old_tb = p40 + old_mid12 + s80
  let new_tb = p40 + new_mid12 + s80
  let patch_tb = @moonbsdiff.diff(old_tb, new_tb, limits).unwrap()
  let info_tb = @moonbsdiff.inspect_deep(patch_tb, limits).unwrap()
  assert_eq(info_tb.control_count, 1L)
  assert_eq(info_tb.diff_bytes, new_tb.length().to_int64())
  assert_eq(info_tb.extra_bytes, 0L)
  assert_eq(@moonbsdiff.apply(old_tb, patch_tb, limits), Ok(new_tb))
  assert_eq(
    fastpath_stream_apply(old_tb, patch_tb, limits),
    Ok((new_tb, info_tb)),
  )

  // Tail Bridge with p == 0 and s = 80.
  let old_tb0 = old_mid12 + s80
  let new_tb0 = new_mid12 + s80
  let patch_tb0 = @moonbsdiff.diff(old_tb0, new_tb0, limits).unwrap()
  let info_tb0 = @moonbsdiff.inspect_deep(patch_tb0, limits).unwrap()
  assert_eq(info_tb0.control_count, 1L)
  assert_eq(info_tb0.extra_bytes, 0L)
  assert_eq(@moonbsdiff.apply(old_tb0, patch_tb0, limits), Ok(new_tb0))

  // Multi-segment mid_plan with backward seek and Tail Bridge at the end.
  let blk_a = fastpath_random(48, 5009U)
  let blk_b = fastpath_random(48, 5018U)
  let gap = fastpath_random(24, 5019U)
  let noise = fastpath_random(24, 5020U)
  let old_multi_tb = p40 + blk_a + blk_b + b"AAAAAAAA" + s80
  let new_multi_tb = p40 + blk_b + blk_a + blk_b + b"BBBBBBBB" + s80
  let patch_multi_tb = @moonbsdiff.diff(old_multi_tb, new_multi_tb, limits).unwrap()
  let info_multi_tb = @moonbsdiff.inspect_deep(patch_multi_tb, limits).unwrap()
  assert_true(info_multi_tb.control_count >= 2L)
  assert_eq(info_multi_tb.extra_bytes, 0L)
  assert_eq(
    @moonbsdiff.apply(old_multi_tb, patch_multi_tb, limits),
    Ok(new_multi_tb),
  )
  assert_eq(
    fastpath_stream_apply(old_multi_tb, patch_multi_tb, limits),
    Ok((new_multi_tb, info_multi_tb)),
  )

  // Multi-segment mid_plan with backward seek and non-Tail-Bridge suffix.
  let old_multi_ntb = p40 + blk_a + gap + blk_b + s80
  let new_multi_ntb = p40 + blk_b + noise + blk_a + s80
  let patch_multi_ntb = @moonbsdiff.diff(old_multi_ntb, new_multi_ntb, limits).unwrap()
  let info_multi_ntb = @moonbsdiff.inspect_deep(patch_multi_ntb, limits).unwrap()
  assert_true(info_multi_ntb.control_count >= 2L)
  assert_true(info_multi_ntb.extra_bytes > 0L)
  assert_eq(
    @moonbsdiff.apply(old_multi_ntb, patch_multi_ntb, limits),
    Ok(new_multi_ntb),
  )
  assert_eq(
    fastpath_stream_apply(old_multi_ntb, patch_multi_ntb, limits),
    Ok((new_multi_ntb, info_multi_ntb)),
  )

  // Tail Bridge NOT triggered: s <= new_rem (s = 10, old_rem = new_rem = 32).
  let p64 = fastpath_random(64, 5010U)
  let s10 = fastpath_random(10, 5011U)
  let old32 = fastpath_random(32, 5012U)
  let new32 = fastpath_random(32, 5013U)
  let old_no_tb = p64 + old32 + s10
  let new_no_tb = p64 + new32 + s10
  let patch_no_tb = @moonbsdiff.diff(old_no_tb, new_no_tb, limits).unwrap()
  let info_no_tb = @moonbsdiff.inspect_deep(patch_no_tb, limits).unwrap()
  assert_true(info_no_tb.control_count >= 2L)
  assert_eq(@moonbsdiff.apply(old_no_tb, patch_no_tb, limits), Ok(new_no_tb))
  assert_eq(
    fastpath_stream_apply(old_no_tb, patch_no_tb, limits),
    Ok((new_no_tb, info_no_tb)),
  )
  fastpath_assert_err(
    @moonbsdiff.diff(old_no_tb, new_no_tb, {
      ..limits,
      max_control_instructions: 1L,
    }),
    ResourceLimitExceeded,
    Matching,
    "segments",
  )

  // Tail Bridge NOT triggered: unequal middle lengths (old_rem != new_rem).
  let old20 = fastpath_random(20, 5014U)
  let new10 = fastpath_random(10, 5015U)
  let s40 = fastpath_random(40, 5016U)
  let old_unequal = p40 + old20 + s40
  let new_unequal = p40 + new10 + s40
  let patch_unequal = @moonbsdiff.diff(old_unequal, new_unequal, limits).unwrap()
  assert_eq(
    @moonbsdiff.apply(old_unequal, patch_unequal, limits),
    Ok(new_unequal),
  )
  fastpath_assert_err(
    @moonbsdiff.diff(old_unequal, new_unequal, {
      ..limits,
      max_control_instructions: 1L,
    }),
    ResourceLimitExceeded,
    Matching,
    "segments",
  )

  // DiffIndex::diff uses full SA on duplicated insert (no 26x regression)
  // and honors DiffOptions compression_level=1 ("BZh1").
  let dup_blk = fastpath_random(1024, 5021U)
  let dup_suf = fastpath_random(128, 5022U)
  let old_dup = dup_blk + dup_suf
  let new_dup = dup_blk + dup_blk + dup_suf
  let dup_index = @moonbsdiff.DiffIndex::build(old_dup, limits).unwrap()
  let dup_patch = dup_index
    .diff(new_dup, { ..limits, max_sort_work: 1L, })
    .unwrap()
  let dup_info = @moonbsdiff.inspect_deep(dup_patch, limits).unwrap()
  assert_true(dup_info.extra_bytes < 64L)
  assert_true(dup_patch.length() < 300)
  assert_eq(@moonbsdiff.apply(old_dup, dup_patch, limits), Ok(new_dup))
  assert_eq(
    fastpath_stream_apply(old_dup, dup_patch, limits),
    Ok((new_dup, dup_info)),
  )

  let idx_lvl1 = dup_index
    .diff_with_options(new_dup, { ..limits, max_sort_work: 1L, }, {
      compression_level: 1,
    })
    .unwrap()
  assert_eq(idx_lvl1[32:36].to_owned(), b"BZh1")
  assert_eq(@moonbsdiff.apply(old_dup, idx_lvl1, limits), Ok(new_dup))

  let standalone_lvl1 = @moonbsdiff.diff_with_options(
    old_big,
    new_big,
    limits,
    { compression_level: 1, },
  ).unwrap()
  assert_eq(standalone_lvl1[32:36].to_owned(), b"BZh1")
  assert_eq(@moonbsdiff.apply(old_big, standalone_lvl1, limits), Ok(new_big))

  fastpath_assert_err(
    @moonbsdiff.diff_with_options(old_dup, new_dup, limits, {
      compression_level: 0,
    }),
    InvalidConfiguration,
    Configuration,
    "compression_level",
  )

  // Case 4 max_decompressed_bytes reports unshifted total (1120) and limit (1096),
  // matching DiffIndex::diff identically.
  let mid_a = fastpath_random(32, 5023U)
  let mid_b = fastpath_random(32, 5024U)
  let mid_gap1 = fastpath_random(8, 5025U)
  let mid_gap2 = fastpath_random(8, 5026U)
  let old_cap = p500 + mid_a + mid_gap1 + mid_b + s500
  let new_cap = p500 + mid_b + mid_gap2 + mid_a + s500
  assert_eq(new_cap.length(), 1072)
  let cap_limits = { ..limits, max_decompressed_bytes: 1096L, }
  let diff_cap_err = match @moonbsdiff.diff(old_cap, new_cap, cap_limits) {
    Ok(_) => abort("expected Case 4 max_decompressed_bytes failure")
    Err(e) => e
  }
  assert_eq(diff_cap_err.kind, ResourceLimitExceeded)
  assert_eq(diff_cap_err.stage, Control)
  assert_eq(diff_cap_err.field, Some("max_decompressed_bytes"))
  assert_eq(diff_cap_err.value, Some(1120L))
  assert_eq(diff_cap_err.limit, Some(1096L))
  let cap_index = @moonbsdiff.DiffIndex::build(old_cap, limits).unwrap()
  assert_eq(cap_index.diff(new_cap, cap_limits), Err(diff_cap_err))
}

///|
test "diff-fastpath-budget-fail-closed" {
  let limits = @moonbsdiff.Limits::for_diff()
  let data = fastpath_random(128, 6001U)
  fastpath_assert_err(
    @moonbsdiff.diff(data, data, { ..limits, max_match_work: 10L, }),
    ResourceLimitExceeded,
    Matching,
    "match_remaining",
  )
  let idx = @moonbsdiff.DiffIndex::build(data, limits).unwrap()
  fastpath_assert_err(
    idx.diff(data, { ..limits, max_match_work: 10L, }),
    ResourceLimitExceeded,
    Matching,
    "match_remaining",
  )
  // Recovery after failure: original budgets succeed cleanly.
  let ok_patch = @moonbsdiff.diff(data, data, limits).unwrap()
  assert_eq(idx.diff(data, limits), Ok(ok_patch))
  assert_eq(@moonbsdiff.apply(data, ok_patch, limits), Ok(data))
}
