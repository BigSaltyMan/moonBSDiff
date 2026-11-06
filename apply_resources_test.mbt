///|
fn resource_exact() -> @moonbsdiff.Limits {
  {
    max_old_bytes: 3L,
    max_new_bytes: 2L,
    max_patch_bytes: 150L,
    max_output_bytes: 2L,
    max_decompressed_bytes: 50L,
    max_control_instructions: 2L,
    max_sort_work: 1L,
    max_match_work: 1L,
  }
}

///|
fn resource_patch() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2c\x00\x00\x00\x00\x00\x00\x00\x25\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xd0\xd5\x33\xc7\x00\x00" +
  b"\x01\x60\x00\x68\x08\x04\x00\x20\x00\x21\x20\x06\x68\x19\x62\x0d\xa2\xe2\xee\x48\xa7\x0a\x12\x1a\x1a\xa6\x78\xe0\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xb1\xf7\x40\x4b\x00\x00\x00\x40\x00\x40" +
  b"\x00\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x16\x3e\xe8\x09\x60\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xef\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a" +
  b"\x12\x1d\xed\x00\xde\x80"
}

///|
test "apply-resource-exact-and-one-short" {
  let old = b"ABC"
  let patch = resource_patch()
  let exact = resource_exact()
  assert_eq(@moonbsdiff.apply(old, patch, exact), Ok(b"AX"))
  let rows = [
    ({ ..exact, max_old_bytes: 2L, }, @moonbsdiff.Header, "max_old_bytes", None),
    (
      { ..exact, max_patch_bytes: 149L, },
      @moonbsdiff.Header,
      "max_patch_bytes",
      None,
    ),
    (
      { ..exact, max_new_bytes: 1L, },
      @moonbsdiff.Header,
      "max_new_bytes",
      Some(24L),
    ),
    (
      { ..exact, max_output_bytes: 1L, },
      @moonbsdiff.Header,
      "max_output_bytes",
      Some(24L),
    ),
    (
      { ..exact, max_decompressed_bytes: 49L, },
      @moonbsdiff.Extra,
      "decompressed_remaining",
      None,
    ),
    (
      { ..exact, max_control_instructions: 1L, },
      @moonbsdiff.Control,
      "block_output_bytes",
      None,
    ),
  ]
  let snapshot = patch.to_array()
  for (limits, stage, field, offset) in rows {
    match @moonbsdiff.apply(old, patch, limits) {
      Ok(_) => abort("one-short limit accepted")
      Err(e) => {
        assert_eq(e.kind, ResourceLimitExceeded)
        assert_eq(e.stage, stage)
        assert_eq(e.field, Some(field))
        assert_eq(e.offset, offset)
      }
    }
    assert_eq(old, b"ABC")
    assert_eq(patch.to_array(), snapshot)
    assert_eq(@moonbsdiff.apply(old, patch, exact), Ok(b"AX"))
  }
}

///|
test "apply-resource-integer-limit-conversions" {
  let limits = {
    ..resource_exact(),
    max_control_instructions: 9223372036854775807L,
    max_decompressed_bytes: 9223372036854775807L,
  }
  assert_eq(@moonbsdiff.apply(b"ABC", resource_patch(), limits), Ok(b"AX"))
}

///|
test "apply-resource-public-defaults" {
  let limits = @moonbsdiff.Limits::for_apply()
  assert_eq(limits.validate(), Ok(()))
  assert_eq(limits.max_old_bytes, 1048576L)
  assert_eq(limits.max_new_bytes, 1048576L)
  assert_eq(limits.max_output_bytes, 1048576L)
  assert_eq(limits.max_patch_bytes, 65536L)
  assert_eq(limits.max_decompressed_bytes, 2097152L)
  assert_eq(limits.max_control_instructions, 16384L)
  assert_eq(limits.max_sort_work, 1L)
  assert_eq(limits.max_match_work, 1L)
  assert_eq(@moonbsdiff.apply(b"ABC", resource_patch(), limits), Ok(b"AX"))
}

///|
fn resource_diff2() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x25\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xa9\x0c\xb8\xa1\x00\x00" +
  b"\x02\x60\x00\x50\x00\x08\x00\x20\x00\x30\xcc\x0c\xf5\x05\xce\x2e\xe4\x8a\x70\xa1\x21\x52\x19\x71\x42\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x51\x13\x7d\x0b\x00\x00\x00\x04\x00\x30\x00\x20\x00" +
  b"\x21\x00\x82\xb1\x77\x24\x53\x85\x09\x05\x11\x37\xd0\xb0\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn resource_diff3() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x26\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xa9\x0c\xb8\xa1\x00\x00" +
  b"\x02\x60\x00\x50\x00\x08\x00\x20\x00\x30\xcc\x0c\xf5\x05\xce\x2e\xe4\x8a\x70\xa1\x21\x52\x19\x71\x42\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xe7\x19\xab\x55\x00\x00\x00\x04\x00\x38\x00\x20\x00" +
  b"\x21\x98\x19\x84\x61\x77\x24\x53\x85\x09\x0e\x71\x9a\xb5\x50\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
test "apply-resource-diff-cap" {
  let limits = @moonbsdiff.Limits::for_apply()
  assert_eq(@moonbsdiff.apply(b"", resource_diff2(), limits), Ok(b"AB"))
  match @moonbsdiff.apply(b"", resource_diff3(), limits) {
    Ok(_) => abort("block cap exceeded")
    Err(e) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Diff)
      assert_eq(e.field, Some("block_output_bytes"))
      assert_eq(e.offset, None)
      assert_eq(e.limit, Some(2L))
    }
  }
  assert_eq(@moonbsdiff.apply(b"", resource_diff2(), limits), Ok(b"AB"))
}

///|
fn resource_extra2() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x5b\x3c\xfd\xb1\x00\x00" +
  b"\x00\x40\x00\x54\x08\x20\x00\x21\x8c\x83\x34\xd1\x09\x5d\x38\xbb\x92\x29\xc2\x84\x82\xd9\xe7\xed\x88\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53" +
  b"\x59\x51\x13\x7d\x0b\x00\x00\x00\x04\x00\x30\x00\x20\x00\x21\x00\x82\xb1\x77\x24\x53\x85\x09\x05\x11\x37\xd0\xb0"
}

///|
fn resource_extra3() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x5b\x3c\xfd\xb1\x00\x00" +
  b"\x00\x40\x00\x54\x08\x20\x00\x21\x8c\x83\x34\xd1\x09\x5d\x38\xbb\x92\x29\xc2\x84\x82\xd9\xe7\xed\x88\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53" +
  b"\x59\xe7\x19\xab\x55\x00\x00\x00\x04\x00\x38\x00\x20\x00\x21\x98\x19\x84\x61\x77\x24\x53\x85\x09\x0e\x71\x9a\xb5\x50"
}

///|
test "apply-resource-extra-cap" {
  let limits = @moonbsdiff.Limits::for_apply()
  assert_eq(@moonbsdiff.apply(b"", resource_extra2(), limits), Ok(b"AB"))
  match @moonbsdiff.apply(b"", resource_extra3(), limits) {
    Ok(_) => abort("block cap exceeded")
    Err(e) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Extra)
      assert_eq(e.field, Some("block_output_bytes"))
      assert_eq(e.offset, None)
      assert_eq(e.limit, Some(2L))
    }
  }
  assert_eq(@moonbsdiff.apply(b"", resource_extra2(), limits), Ok(b"AB"))
}
