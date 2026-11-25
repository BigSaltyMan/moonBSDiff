///|
fn analyze_random(length : Int32, seed : UInt32) -> Bytes {
  let mut state = seed
  let bytes : Array[Byte] = []
  for _ in 0..<length {
    state = state * 1664525U + 1013904223U
    bytes.push((state >> 24).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
fn analyze_has_flag(
  analysis : @moonbsdiff.PatchAnalysis,
  code : String,
  severity : @moonbsdiff.RiskLevel,
) -> Bool {
  for flag in analysis.risk_flags {
    if flag.code == code && flag.severity == severity {
      return true
    }
  }
  false
}

///|
fn assert_required_limits_roundtrip(
  patch : Bytes,
  analysis : @moonbsdiff.PatchAnalysis,
) -> Unit raise {
  let req = analysis.required_limits
  assert_eq(req.validate(), Ok(()))
  assert_eq(@moonbsdiff.inspect_deep(patch, req), Ok(analysis.deep))
  assert_eq(@moonbsdiff.analyze_patch(patch, req), Ok(analysis))
  if req.max_patch_bytes > 1L {
    assert_true(
      @moonbsdiff.inspect_deep(patch, {
        ..req,
        max_patch_bytes: req.max_patch_bytes - 1L,
      })
      is Err({ kind: ResourceLimitExceeded, .. }),
    )
  }
  if req.max_new_bytes > 1L {
    assert_true(
      @moonbsdiff.inspect_deep(patch, {
        ..req,
        max_new_bytes: req.max_new_bytes - 1L,
      })
      is Err({ kind: ResourceLimitExceeded, .. }),
    )
  }
  if req.max_output_bytes > 1L {
    assert_true(
      @moonbsdiff.inspect_deep(patch, {
        ..req,
        max_output_bytes: req.max_output_bytes - 1L,
      })
      is Err({ kind: ResourceLimitExceeded, .. }),
    )
  }
  if req.max_decompressed_bytes > 1L {
    assert_true(
      @moonbsdiff.inspect_deep(patch, {
        ..req,
        max_decompressed_bytes: req.max_decompressed_bytes - 1L,
      })
      is Err({ kind: ResourceLimitExceeded, .. }),
    )
  }
  if req.max_control_instructions > 1L {
    assert_true(
      @moonbsdiff.inspect_deep(patch, {
        ..req,
        max_control_instructions: req.max_control_instructions - 1L,
      })
      is Err({ kind: ResourceLimitExceeded, .. }),
    )
  }
}

///|
// Fixed BSDIFF40 fixture with 3 controls: (2, 1, -5), (0, 0, 4), (1, 2, 0).
fn analyze_fixed_sample() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x35\x00\x00\x00\x00\x00\x00\x00" +
  b"\x26\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00" +
  b"\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xbc\xe4\x9e\x4b\x00\x00" +
  b"\x0f\x40\x40\x7e\x0c\x40\x00\x20\x00\x31\x06\x4c\x40\x92\x68\xd2" +
  b"\x69\x26\x61\x5d\x10\x8d\x3d\x4d\x1c\xd9\x3e\x2e\xe4\x8a\x70\xa1" +
  b"\x21\x79\xc9\x3c\x96\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x64" +
  b"\x8c\xbb\x73\x00\x00\x00\x01\x00\x38\x00\x20\x00\x21\x98\x19\x84" +
  b"\x61\x77\x24\x53\x85\x09\x06\x48\xcb\xb7\x30\x42\x5a\x68\x39\x31" +
  b"\x41\x59\x26\x53\x59\x73\xa4\x07\x77\x00\x00\x00\x02\x00\x00\x70" +
  b"\x20\x00\x21\x98\x19\x84\x61\x77\x24\x53\x85\x09\x07\x3a\x40\x77" +
  b"\x70"
}

///|
test "analyze healthy patch reports low risk and exact metrics" {
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let old = analyze_random(4096, 7001U)
  let mutated = old.to_array()
  for i in 0..<24 {
    mutated[2000 + i] = ((mutated[2000 + i].to_int() + 17) & 0xff).to_byte()
  }
  let new = Bytes::from_array(mutated)
  let patch = @moonbsdiff.diff(old, new, diff_limits).unwrap()
  let deep = @moonbsdiff.inspect_deep(patch, apply_limits).unwrap()
  let analysis = @moonbsdiff.analyze_patch(patch, apply_limits).unwrap()
  assert_eq(analysis.deep, deep)
  assert_eq(analysis.ctrl_compressed_bytes, deep.header.control_length)
  assert_eq(analysis.diff_compressed_bytes, deep.header.diff_length)
  assert_eq(analysis.extra_compressed_bytes, deep.header.extra_length)
  assert_eq(
    analysis.total_compressed_bytes,
    analysis.ctrl_compressed_bytes +
    analysis.diff_compressed_bytes +
    analysis.extra_compressed_bytes,
  )
  assert_eq(analysis.total_compressed_bytes + 32L, deep.header.patch_bytes)
  assert_eq(analysis.diff_share_permille, 1000L)
  assert_eq(analysis.extra_share_permille, 0L)
  assert_true(analysis.patch_to_output_permille < 1000L)
  assert_eq(analysis.risk_level, @moonbsdiff.Low)
  assert_eq(analysis.risk_flags.length(), 0)
  assert_true(analysis.sample_controls.length() >= 1)
  assert_eq(analysis.sample_controls[0].index, 0L)
  assert_required_limits_roundtrip(patch, analysis)
}

///|
test "analyze fast-path and empty patches" {
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let fast_limits = { ..diff_limits, max_sort_work: 1L, }

  // Pure identical fast-path (2048 bytes, 1 control).
  let blob = analyze_random(2048, 7002U)
  let ident_patch = @moonbsdiff.diff(blob, blob, fast_limits).unwrap()
  let ident = @moonbsdiff.analyze_patch(ident_patch, apply_limits).unwrap()
  assert_eq(ident.deep.control_count, 1L)
  assert_eq(ident.deep.diff_bytes, 2048L)
  assert_eq(ident.deep.extra_bytes, 0L)
  assert_eq(ident.diff_share_permille, 1000L)
  assert_eq(ident.extra_share_permille, 0L)
  assert_eq(ident.negative_seek_count, 0L)
  assert_eq(ident.max_abs_seek, 0L)
  assert_eq(ident.risk_level, @moonbsdiff.Low)
  assert_eq(ident.risk_flags.length(), 0)
  assert_eq(ident.sample_controls.length(), 1)
  assert_eq(ident.sample_controls[0], {
    index: 0L,
    add_bytes: 2048L,
    extra_bytes: 0L,
    seek_offset: 0L,
  })
  assert_required_limits_roundtrip(ident_patch, ident)

  // Pure middle-insert fast-path (2 controls).
  let pre = analyze_random(1024, 7003U)
  let suf = analyze_random(1024, 7004U)
  let ins = b"FASTPATH-INSERT!"
  let ins_patch = @moonbsdiff.diff(pre + suf, pre + ins + suf, fast_limits).unwrap()
  let ins_analysis = @moonbsdiff.analyze_patch(ins_patch, apply_limits).unwrap()
  assert_eq(ins_analysis.deep.control_count, 2L)
  assert_eq(ins_analysis.deep.diff_bytes, 2048L)
  assert_eq(ins_analysis.deep.extra_bytes, 16L)
  assert_eq(ins_analysis.risk_level, @moonbsdiff.Low)
  assert_eq(ins_analysis.sample_controls.length(), 2)
  assert_eq(ins_analysis.sample_controls[0], {
    index: 0L,
    add_bytes: 1024L,
    extra_bytes: 16L,
    seek_offset: 0L,
  })
  assert_eq(ins_analysis.sample_controls[1], {
    index: 1L,
    add_bytes: 1024L,
    extra_bytes: 0L,
    seek_offset: 0L,
  })
  assert_required_limits_roundtrip(ins_patch, ins_analysis)

  // Empty patch (0 output bytes, 74-byte canonical envelope, 0 controls, 0 expanded bytes).
  let empty_patch = @moonbsdiff.diff(b"", b"", diff_limits).unwrap()
  let empty = @moonbsdiff.analyze_patch(empty_patch, apply_limits).unwrap()
  assert_eq(empty.deep.header.patch_bytes, 74L)
  assert_eq(empty.deep.header.new_bytes, 0L)
  assert_eq(empty.deep.control_count, 0L)
  assert_eq(empty.deep.expanded_bytes, 0L)
  assert_eq(empty.expansion_ratio_permille, 0L)
  assert_eq(empty.diff_share_permille, 0L)
  assert_eq(empty.extra_share_permille, 0L)
  assert_eq(empty.patch_to_output_permille, 0L)
  assert_eq(empty.risk_level, @moonbsdiff.Low)
  assert_eq(empty.risk_flags.length(), 0)
  assert_eq(empty.sample_controls.length(), 0)
  assert_eq(empty.required_limits.max_new_bytes, 1L)
  assert_eq(empty.required_limits.max_output_bytes, 1L)
  assert_eq(empty.required_limits.max_decompressed_bytes, 1L)
  assert_eq(empty.required_limits.max_control_instructions, 1L)
  assert_required_limits_roundtrip(empty_patch, empty)
}

///|
test "analyze high-expansion bzip2 patches under generous and tight limits" {
  // Identical zero blocks trigger fast-path (no suffix sort) and compress
  // 100 KiB / 24 KiB of zero diffs down to ~100 compressed bytes.
  let generous_diff : @moonbsdiff.Limits = {
    ..@moonbsdiff.Limits::for_diff(),
    max_old_bytes: 131072L,
    max_new_bytes: 131072L,
    max_output_bytes: 131072L,
    max_decompressed_bytes: 262144L,
    max_sort_work: 1L,
  }
  let generous_apply = @moonbsdiff.Limits::for_apply()

  // High severity: >= 100,000 permille AND expanded_bytes >= 65536.
  let zeros_100k = Bytes::from_array(Array::make(100000, b'\x00'))
  let bomb_patch = @moonbsdiff.diff(zeros_100k, zeros_100k, generous_diff).unwrap()
  let bomb = @moonbsdiff.analyze_patch(bomb_patch, generous_apply).unwrap()
  assert_true(bomb.deep.expanded_bytes >= 100024L)
  assert_true(bomb.total_compressed_bytes < 512L)
  assert_true(bomb.expansion_ratio_permille >= 100_000L)
  assert_eq(bomb.risk_level, @moonbsdiff.High)
  assert_true(analyze_has_flag(bomb, "HIGH_EXPANSION_RATIO", @moonbsdiff.High))
  assert_required_limits_roundtrip(bomb_patch, bomb)

  // Under tight decompression limits, bomb fails closed identically to inspect_deep.
  let tight = { ..generous_apply, max_decompressed_bytes: 8192L, }
  match
    (
      @moonbsdiff.analyze_patch(bomb_patch, tight),
      @moonbsdiff.inspect_deep(bomb_patch, tight),
    ) {
    (Err(a_err), Err(i_err)) => {
      assert_eq(a_err, i_err)
      assert_eq(a_err.kind, @moonbsdiff.ResourceLimitExceeded)
    }
    _ => abort("tight limit must reject high-expansion bomb")
  }

  // Elevated severity: >= 20,000 permille AND 16384 <= expanded_bytes < 65536.
  let zeros_24k = Bytes::from_array(Array::make(24576, b'\x00'))
  let mid_patch = @moonbsdiff.diff(zeros_24k, zeros_24k, generous_diff).unwrap()
  let mid = @moonbsdiff.analyze_patch(mid_patch, generous_apply).unwrap()
  assert_true(mid.deep.expanded_bytes >= 16384L)
  assert_true(mid.deep.expanded_bytes < 65536L)
  assert_true(mid.expansion_ratio_permille >= 20_000L)
  assert_eq(mid.risk_level, @moonbsdiff.Elevated)
  assert_true(
    analyze_has_flag(mid, "HIGH_EXPANSION_RATIO", @moonbsdiff.Elevated),
  )
  assert_required_limits_roundtrip(mid_patch, mid)
}

///|
test "analyze patch-larger-than-output and fixed negative seek vector" {
  let apply_limits = @moonbsdiff.Limits::for_apply()
  // Fixed fixture: 161-byte patch for 6-byte output, controls (2,1,-5), (0,0,4), (1,2,0).
  let fixed = analyze_fixed_sample()
  let analysis = @moonbsdiff.analyze_patch(fixed, apply_limits).unwrap()
  assert_eq(analysis.ctrl_compressed_bytes, 53L)
  assert_eq(analysis.diff_compressed_bytes, 38L)
  assert_eq(analysis.extra_compressed_bytes, 38L)
  assert_eq(analysis.total_compressed_bytes, 129L)
  assert_eq(analysis.diff_share_permille, 500L)
  assert_eq(analysis.extra_share_permille, 500L)
  assert_eq(analysis.patch_to_output_permille, 26833L)
  assert_eq(analysis.negative_seek_count, 1L)
  assert_eq(analysis.max_abs_seek, 5L)
  assert_eq(analysis.risk_level, @moonbsdiff.Elevated)
  assert_true(
    analyze_has_flag(analysis, "PATCH_LARGER_THAN_OUTPUT", @moonbsdiff.Elevated),
  )
  assert_eq(analysis.sample_controls.length(), 3)
  assert_eq(analysis.sample_controls[0], {
    index: 0L,
    add_bytes: 2L,
    extra_bytes: 1L,
    seek_offset: -5L,
  })
  assert_eq(analysis.sample_controls[1], {
    index: 1L,
    add_bytes: 0L,
    extra_bytes: 0L,
    seek_offset: 4L,
  })
  assert_eq(analysis.sample_controls[2], {
    index: 2L,
    add_bytes: 1L,
    extra_bytes: 2L,
    seek_offset: 0L,
  })
  assert_required_limits_roundtrip(fixed, analysis)

  // Generated small patch whose envelope exceeds output size.
  let small_patch = @moonbsdiff.diff(
    b"hello",
    b"world",
    @moonbsdiff.Limits::for_diff(),
  ).unwrap()
  let small = @moonbsdiff.analyze_patch(small_patch, apply_limits).unwrap()
  assert_true(small.deep.header.patch_bytes >= small.deep.header.new_bytes)
  assert_true(small.patch_to_output_permille >= 1000L)
  assert_eq(small.risk_level, @moonbsdiff.Elevated)
  assert_true(
    analyze_has_flag(small, "PATCH_LARGER_THAN_OUTPUT", @moonbsdiff.Elevated),
  )
  assert_required_limits_roundtrip(small_patch, small)

  // Extreme negative seek boundary: single control (0, 1, -9223372036854775807L).
  let extreme_seek_patch = b"\x42\x53\x44\x49\x46\x46\x34\x30\x2e\x00\x00\x00\x00\x00\x00\x00" +
    b"\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00" +
    b"\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x85\xe4\x5a\xdd\x00\x00" +
    b"\x00\xc0\x00\xec\x00\x00\x00\xa0\x00\x30\xcd\x01\x1b\xd5\x1a\x3b" +
    b"\x72\x14\x97\xc5\xdc\x91\x4e\x14\x24\x21\x79\x16\xb7\x40\x42\x5a" +
    b"\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39" +
    b"\x31\x41\x59\x26\x53\x59\xe6\xea\x3d\x9a\x00\x00\x00\x02\x00\x00" +
    b"\x10\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1c\xdd\x47\xb3" +
    b"\x40"
  let extreme = @moonbsdiff.analyze_patch(extreme_seek_patch, apply_limits).unwrap()
  assert_eq(extreme.negative_seek_count, 1L)
  assert_eq(extreme.max_abs_seek, 9223372036854775807L)
  assert_eq(extreme.sample_controls.length(), 1)
  assert_eq(extreme.sample_controls[0], {
    index: 0L,
    add_bytes: 0L,
    extra_bytes: 1L,
    seek_offset: -9223372036854775807L,
  })
  assert_required_limits_roundtrip(extreme_seek_patch, extreme)
}

///|
test "analyze high-extra random patch flags HIGH_EXTRA_RATIO" {
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let old = analyze_random(512, 8101U)
  let new = analyze_random(512, 8102U)
  let patch = @moonbsdiff.diff(old, new, diff_limits).unwrap()
  let analysis = @moonbsdiff.analyze_patch(patch, apply_limits).unwrap()
  assert_eq(analysis.deep.header.new_bytes, 512L)
  assert_true(analysis.extra_share_permille >= 850L)
  assert_eq(analysis.risk_level, @moonbsdiff.Elevated)
  assert_true(
    analyze_has_flag(analysis, "HIGH_EXTRA_RATIO", @moonbsdiff.Elevated),
  )
  assert_required_limits_roundtrip(patch, analysis)
}

///|
fn analyze_concat_blocks(blocks : Array[Bytes], reverse : Bool) -> Bytes {
  let out : Array[Byte] = []
  let count = blocks.length()
  for i in 0..<count {
    let idx = if reverse { count - 1 - i } else { i }
    for b in blocks[idx] {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
test "analyze truncates sample_controls at 64 and flags excessive control density" {
  let diff_limits : @moonbsdiff.Limits = {
    ..@moonbsdiff.Limits::for_diff(),
    max_control_instructions: 4096L,
    max_decompressed_bytes: 262144L,
  }
  let apply_limits = @moonbsdiff.Limits::for_apply()

  // Reversed distinct 24-byte blocks force ~80 controls (>64) with negative seeks.
  let blocks80 : Array[Bytes] = []
  for i in 0..<80 {
    blocks80.push(analyze_random(24, 9000U + i.reinterpret_as_uint()))
  }
  let old80 = analyze_concat_blocks(blocks80, false)
  let new80 = analyze_concat_blocks(blocks80, true)
  let patch80 = @moonbsdiff.diff(old80, new80, diff_limits).unwrap()
  let a80 = @moonbsdiff.analyze_patch(patch80, apply_limits).unwrap()
  assert_true(a80.deep.control_count > 64L)
  assert_eq(a80.sample_controls.length(), 64)
  assert_eq(a80.sample_controls[0].index, 0L)
  assert_eq(a80.sample_controls[63].index, 63L)
  assert_true(a80.negative_seek_count > 0L)
  assert_true(a80.max_abs_seek > 0L)
  assert_required_limits_roundtrip(patch80, a80)

  // Elevated control density: >= 256 controls and control_count * 64 > new_bytes.
  let blocks300 : Array[Bytes] = []
  for i in 0..<300 {
    blocks300.push(analyze_random(20, 9500U + i.reinterpret_as_uint()))
  }
  let old300 = analyze_concat_blocks(blocks300, false)
  let new300 = analyze_concat_blocks(blocks300, true)
  let patch300 = @moonbsdiff.diff(old300, new300, diff_limits).unwrap()
  let a300 = @moonbsdiff.analyze_patch(patch300, apply_limits).unwrap()
  assert_true(a300.deep.control_count >= 256L)
  assert_true(a300.deep.control_count * 64L > a300.deep.header.new_bytes)
  assert_eq(a300.sample_controls.length(), 64)
  assert_true(
    analyze_has_flag(a300, "EXCESSIVE_CONTROL_DENSITY", @moonbsdiff.Elevated),
  )
  assert_required_limits_roundtrip(patch300, a300)

  // High control density: >= 1024 controls and control_count * 16 > new_bytes.
  let blocks1100 : Array[Bytes] = []
  for i in 0..<1100 {
    blocks1100.push(analyze_random(12, 10000U + i.reinterpret_as_uint()))
  }
  let old1100 = analyze_concat_blocks(blocks1100, false)
  let new1100 = analyze_concat_blocks(blocks1100, true)
  let patch1100 = @moonbsdiff.diff(old1100, new1100, diff_limits).unwrap()
  let a1100 = @moonbsdiff.analyze_patch(patch1100, apply_limits).unwrap()
  assert_true(a1100.deep.control_count >= 1024L)
  assert_true(a1100.deep.control_count * 16L > a1100.deep.header.new_bytes)
  assert_eq(a1100.sample_controls.length(), 64)
  assert_eq(a1100.risk_level, @moonbsdiff.High)
  assert_true(
    analyze_has_flag(a1100, "EXCESSIVE_CONTROL_DENSITY", @moonbsdiff.High),
  )
  assert_required_limits_roundtrip(patch1100, a1100)
}

///|
test "analyze corrupt, truncated, and limit errors match inspect_deep identically" {
  let base = @moonbsdiff.Limits::for_apply()
  let valid = analyze_fixed_sample()
  let diff_crc = valid[:95].to_owned() + b"\x65" + valid[96:].to_owned()
  let ctrl_crc = valid[:43].to_owned() + b"\x00" + valid[44:].to_owned()
  let extra_trunc = valid[:valid.length() - 5].to_owned()
  let empty_bz2 = b"\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
  let bad_marker = b"BSDIFF40" +
    b"\x0a\x00\x00\x00\x00\x00\x00\x00" +
    b"\x0e\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    b"BZh9BADMRK" +
    empty_bz2 +
    empty_bz2
  let bad_magic = b"NOTBSDIF" + valid[8:].to_owned()
  for
    (patch, limits) in [
      (b"", base),
      (b"BSDIFF40", base),
      (bad_magic, base),
      (ctrl_crc, base),
      (diff_crc, base),
      (extra_trunc, base),
      (bad_marker, base),
      (valid, { ..base, max_patch_bytes: 0L, }),
      (valid, { ..base, max_patch_bytes: 160L, }),
      (valid, { ..base, max_output_bytes: 5L, }),
      (valid, { ..base, max_new_bytes: 5L, }),
      (valid, { ..base, max_decompressed_bytes: 77L, }),
      (valid, { ..base, max_control_instructions: 2L, }),
    ] {
    let expected = @moonbsdiff.inspect_deep(patch, limits)
    let actual = @moonbsdiff.analyze_patch(patch, limits)
    match (actual, expected) {
      (Err(a_err), Err(e_err)) => assert_eq(a_err, e_err)
      _ => abort("expected matching error from analyze_patch and inspect_deep")
    }
  }

  // Bloated zero-output patch (> 74 bytes via concatenated empty bzip2 streams)
  // fails closed identically in analyze_patch and inspect_deep.
  let bloated_zero_output = b"BSDIFF40" +
    b"\x1c\x00\x00\x00\x00\x00\x00\x00" +
    b"\x0e\x00\x00\x00\x00\x00\x00\x00" +
    b"\x00\x00\x00\x00\x00\x00\x00\x00" +
    empty_bz2 +
    empty_bz2 +
    empty_bz2 +
    empty_bz2
  assert_eq(bloated_zero_output.length(), 88)
  match
    (
      @moonbsdiff.analyze_patch(bloated_zero_output, base),
      @moonbsdiff.inspect_deep(bloated_zero_output, base),
    ) {
    (Err(a_err), Err(e_err)) => {
      assert_eq(a_err, e_err)
      assert_eq(a_err.kind, @moonbsdiff.InvalidField)
    }
    _ => abort("bloated multi-stream zero-output patch must fail closed")
  }

  // 173-byte BZh9 BWT bomb (898k BWT bytes in each of control/diff/extra) must
  // abort inside MTF before inverse-BWT under tight limits, matching apply/inspect_deep.
  let bwt_bomb_patch = b"\x42\x53\x44\x49\x46\x46\x34\x30\x33\x00\x00\x00\x00\x00\x00\x00" +
    b"\x2d\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00" +
    b"\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xfb\xea\x6c\xd9\x03\x6c" +
    b"\xf7\xc0\x00\x68\x04\x20\x00\x30\xcd\x34\x13\x52\x9a\x6b\x56\x14" +
    b"\x14\x44\xd6\xf7\x72\x90\x51\x13\xe2\xee\x48\xa7\x0a\x12\x1f\x7d" +
    b"\x4d\x9b\x20\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xa2\x8c\x78" +
    b"\xe4\x00\x00\x00\x40\x00\x60\x00\x20\x00\x30\x80\x4d\x46\xa9\x05" +
    b"\x11\x32\x90\x51\x13\x8b\xb9\x22\x9c\x28\x48\x51\x46\x3c\x72\x00" +
    b"\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xa2\x8c\x78\xe4\x00\x00" +
    b"\x00\x40\x00\x60\x00\x20\x00\x30\x80\x4d\x46\xa9\x05\x11\x32\x90" +
    b"\x51\x13\x8b\xb9\x22\x9c\x28\x48\x51\x46\x3c\x72\x00"
  assert_eq(bwt_bomb_patch.length(), 173)
  let tight_bomb_limits : @moonbsdiff.Limits = {
    ..base,
    max_patch_bytes: 256L,
    max_new_bytes: 2L,
    max_output_bytes: 2L,
    max_decompressed_bytes: 26L,
    max_control_instructions: 1L,
  }
  match
    (
      @moonbsdiff.analyze_patch(bwt_bomb_patch, tight_bomb_limits),
      @moonbsdiff.inspect_deep(bwt_bomb_patch, tight_bomb_limits),
      @moonbsdiff.apply(b"AB", bwt_bomb_patch, tight_bomb_limits),
    ) {
    (Err(a_err), Err(i_err), Err(ap_err)) => {
      assert_eq(a_err, i_err)
      assert_eq(a_err, ap_err)
      assert_eq(a_err.kind, @moonbsdiff.ResourceLimitExceeded)
      assert_eq(a_err.stage, @moonbsdiff.Control)
    }
    _ =>
      abort(
        "173-byte BZh9 BWT bomb must fail closed across analyze/inspect/apply",
      )
  }
}
