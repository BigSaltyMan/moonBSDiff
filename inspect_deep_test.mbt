// Fixed Python bz2 fixtures from scripts/test_cli_inspect_deep.py.
// The nonempty sample uses (2, 1, -5), (0, 0, 4), (1, 2, 0), abc and XYZ.

///|
fn deep_sample() -> Bytes {
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
fn deep_empty_sample() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x0e\x00\x00\x00\x00\x00\x00\x00" +
  b"\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" +
  b"\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a" +
  b"\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39" +
  b"\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
test "inspect deep public statistics and header" {
  match
    @moonbsdiff.inspect_deep(deep_sample(), @moonbsdiff.Limits::for_apply()) {
    Ok(info) => {
      assert_eq(info.header.patch_bytes, 161L)
      assert_eq(info.header.new_bytes, 6L)
      assert_eq(
        (info.header.control_start, info.header.control_length),
        (32L, 53L),
      )
      assert_eq((info.header.diff_start, info.header.diff_length), (85L, 38L))
      assert_eq(
        (info.header.extra_start, info.header.extra_length),
        (123L, 38L),
      )
      assert_eq(info.control_count, 3L)
      assert_eq(info.diff_bytes, 3L)
      assert_eq(info.extra_bytes, 3L)
      assert_eq(info.expanded_bytes, 78L)
    }
    Err(_) => abort("valid patch rejected")
  }
}

///|
test "inspect deep public CRC errors identify the stream" {
  let patch = deep_sample()
  // Flip the first Diff block CRC byte and the empty Extra stream CRC.
  let diff_crc = patch[:95].to_owned() + b"\x65" + patch[96:].to_owned()
  let empty = deep_empty_sample()
  let empty_crc = empty[:73].to_owned() + b"\x01"
  for
    (damaged, stage, block, new_size) in [
      (diff_crc, @moonbsdiff.Diff, "diff", 6L),
      (empty_crc, @moonbsdiff.Extra, "extra", 0L),
    ] {
    match @moonbsdiff.inspect_header(damaged, 161L) {
      Ok(header) => assert_eq(header.new_bytes, new_size)
      Err(_) => abort("CRC fixture must have a valid header")
    }
    match @moonbsdiff.inspect_deep(damaged, @moonbsdiff.Limits::for_apply()) {
      Err(error) =>
        assert_eq(error, @moonbsdiff.BsdiffError::{
          kind: DecompressionFailed,
          stage,
          block: Some(block),
          offset: None,
          field: Some("crc"),
          value: None,
          limit: None,
        })
      Ok(_) => abort("CRC corruption accepted")
    }
  }
}

///|
test "inspect deep public shared budget and retry" {
  let patch = deep_sample()
  let before = deep_sample()
  let limits = {
    ..@moonbsdiff.Limits::for_apply(),
    max_decompressed_bytes: 78L,
  }
  for budget in [78L, 77L, 78L] {
    match
      @moonbsdiff.inspect_deep(patch, {
        ..limits,
        max_decompressed_bytes: budget,
      }) {
      Ok(info) => {
        assert_eq(budget, 78L)
        assert_eq(info.expanded_bytes, 78L)
      }
      Err(error) =>
        assert_eq(
          (
            budget,
            error.kind,
            error.stage,
            error.block,
            error.field,
            error.value,
            error.limit,
          ),
          (
            77L,
            @moonbsdiff.ResourceLimitExceeded,
            @moonbsdiff.Extra,
            Some("extra"),
            Some("decompressed_remaining"),
            Some(1L),
            Some(0L),
          ),
        )
    }
    assert_eq(patch, before)
  }
}
