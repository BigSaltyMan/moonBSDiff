///|
fn stream_test_random(length : Int32, seed : UInt32) -> Bytes {
  let mut state = seed
  let bytes : Array[Byte] = []
  for _ in 0..<length {
    state = state * 1664525U + 1013904223U
    bytes.push((state >> 24).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(bytes)
}

///|
fn stream_test_run_chunked(
  old : Bytes,
  patch : Bytes,
  limits : @moonbsdiff.Limits,
  old_step : Int32,
  patch_step : Int32,
  stages : Array[@moonbsdiff.StreamApplyStage],
) -> Result[
  (Bytes, @moonbsdiff.DeepPatchInfo, Int32, Int32, Int32),
  @moonbsdiff.StreamApplyError[String],
] {
  let out : Array[Byte] = []
  let mut old_calls = 0
  let mut patch_calls = 0
  let mut checkpoints = 0
  match
    @moonbsdiff.apply_stream(
      old.length().to_int64(),
      patch.length().to_int64(),
      limits,
      read_old_at=(offset, count) => {
        try! assert_true(count >= 1 && count <= 4096)
        old_calls += 1
        let start = offset.to_int()
        let take = Int32::min(old_step, count)
        let end = Int32::min(old.length(), start + take)
        Ok(old[start:end].to_owned())
      },
      read_patch_at=(offset, count) => {
        try! assert_true(count >= 1 && count <= 4096)
        patch_calls += 1
        let start = offset.to_int()
        let take = Int32::min(patch_step, count)
        let end = Int32::min(patch.length(), start + take)
        Ok(patch[start:end].to_owned())
      },
      write_output=chunk => {
        try! assert_true(chunk.length() >= 1 && chunk.length() <= 4096)
        for b in chunk {
          out.push(b)
        }
        Ok(())
      },
      on_stage=stage => {
        stages.push(stage)
        Ok(())
      },
      checkpoint=() => {
        checkpoints += 1
        Ok(())
      },
    ) {
    Ok(info) =>
      Ok((Bytes::from_array(out), info, old_calls, patch_calls, checkpoints))
    Err(e) => Err(e)
  }
}

///|
fn stream_test_assert_bsdiff(
  result : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[String],
  ],
  kind : @moonbsdiff.ErrorKind,
  stage : @moonbsdiff.ErrorStage,
  field : String?,
) -> Unit raise {
  match result {
    Ok(_) => abort("expected stream apply failure")
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, kind)
      assert_eq(e.stage, stage)
      assert_eq(e.field, field)
    }
    Err(Io(msg)) => abort("unexpected Io error: " + msg)
  }
}

///|
fn patch_int64_min() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x35\x00\x00\x00\x00\x00\x00\x00\x28\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xe9\x10\xed\x85\x00\x00\x01\x60\x40\xf4\x04\x08\x00\x40\x00\x00\x00\xa0\x00\x21\x89\xa6\x9a\x10\xc0\x84\xe2\x60\x18\xad\xc3\x59\xdf\x17\x72\x45\x38\x50\x90\xe9\x10\xed\x85\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x9e\xd7\xf7\x77\x00\x00\x00\x82\x00\x00\xf0\x20\x00\x21\x9a\x68\x33\x4d\x13\x3c\x5d\xc9\x14\xe1\x42\x42\x7b\x5f\xdd\xdc\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_outside_both() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x30\x00\x00\x00\x00\x00\x00\x00\x28\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xf4\xc9\x90\x89\x00\x00\x00\xe0\x40\x52\x04\x08\x00\x40\x00\x20\x00\x21\xa7\xa9\x80\xc0\x08\xdf\x25\x0a\x2b\x85\xdc\x91\x4e\x14\x24\x3d\x32\x64\x22\x40\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x5a\x3d\x60\x5c\x00\x00\x01\x40\x00\x72\x00\x20\x00\x21\x8c\x83\x34\xd0\xca\x71\x77\x24\x53\x85\x09\x05\xa3\xd6\x05\xc0\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_outside_high() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2e\x00\x00\x00\x00\x00\x00\x00\x26\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xe0\x96\x8b\x8f\x00\x00\x00\xe0\x00\x48\x14\x08\x00\x20\x00\x30\xcd\x00\x94\xf5\x31\xf6\x4e\x05\xa9\x85\xdc\x91\x4e\x14\x24\x38\x25\xa2\xe3\xc0\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x73\xa4\x07\x77\x00\x00\x00\x02\x00\x00\x70\x20\x00\x21\x98\x19\x84\x61\x77\x24\x53\x85\x09\x07\x3a\x40\x77\x70\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_neg_x() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2b\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x90\x2f\x7b\x96\x00\x00\x04\x40\x40\x70\x04\x40\x00\x20\x00\x21\x83\x41\x9a\x08\x54\xc8\x8e\x2e\xe4\x8a\x70\xa1\x21\x20\x5e\xf7\x2c\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_neg_y() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2d\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xe9\xcc\xe2\x17\x00\x00\x01\x40\x40\x74\x00\x40\x00\x20\x00\x30\xcd\x00\xcd\x47\xa0\xbf\x64\x0a\xe1\x77\x24\x53\x85\x09\x0e\x9c\xce\x21\x70\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_oob_x() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xa9\x0c\xb8\xa1\x00\x00\x02\x60\x00\x50\x00\x08\x00\x20\x00\x30\xcc\x0c\xf5\x05\xce\x2e\xe4\x8a\x70\xa1\x21\x52\x19\x71\x42\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_oob_y() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x5b\x3c\xfd\xb1\x00\x00\x00\x40\x00\x54\x08\x20\x00\x21\x8c\x83\x34\xd1\x09\x5d\x38\xbb\x92\x29\xc2\x84\x82\xd9\xe7\xed\x88\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_ovf_x() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x33\x00\x00\x00\x00\x00\x00\x00\x25\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xad\x2f\x03\xc1\x00\x00\x00\x60\x80\xe8\x04\x08\x00\x00\x00\x80\x00\xa0\x00\x31\x0c\x00\xc9\xea\x32\x70\x27\x28\xa0\xef\x8b\xb9\x22\x9c\x28\x48\x56\x97\x81\xe0\x80\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xef\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\xed\x00\xde\x80\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_ovf_z() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x33\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x8f\x96\xfd\x83\x00\x00\x01\xc0\x80\xec\x04\x00\x00\x80\x00\xa0\x00\x21\x22\x68\xd0\x86\x01\x9d\x20\x27\xb8\x56\x4c\x57\xc5\xdc\x91\x4e\x14\x24\x23\xe5\xbf\x60\xc0\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xef\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\xed\x00\xde\x80"
}

///|
fn patch_udf_z() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x35\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xaa\x75\x05\xe4\x00\x00\x02\xc0\x40\xfc\x04\x40\x00\x00\x00\xa0\x00\x21\xb4\x83\x41\x0c\x08\x64\xd7\x68\x4a\x4c\xb3\x99\xca\x8d\xf1\x77\x24\x53\x85\x09\x0a\xa7\x50\x5e\x40\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xef\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\xed\x00\xde\x80"
}

///|
fn patch_ctrl_short() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x25\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xef\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\xed\x00\xde\x80\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_diff_short() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x52\xfc\x1e\x77\x00\x00\x02\x60\x00\x60\x00\x08\x00\x20\x00\x30\xcc\x0c\xf5\x05\xce\x2e\xe4\x8a\x70\xa1\x20\xa5\xf8\x3c\xee\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_extra_short() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x2b\xe4\x3c\xff\x00\x00\x00\x40\x00\x64\x08\x20\x00\x21\x8c\x83\x34\xd1\x09\x5d\x38\xbb\x92\x29\xc2\x84\x81\x5f\x21\xe7\xf8\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_unused_ctrl() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x27\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x04\x53\x83\xc5\x00\x00\x00\x60\x00\x40\x00\x04\x00\x20\x00\x21\x00\x82\x83\x17\x72\x45\x38\x50\x90\x04\x53\x83\xc5\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_unused_diff() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x25\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x2b\xe4\x3c\xff\x00\x00\x00\x40\x00\x64\x08\x20\x00\x21\x8c\x83\x34\xd1\x09\x5d\x38\xbb\x92\x29\xc2\x84\x81\x5f\x21\xe7\xf8\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xef\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\xed\x00\xde\x80\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xeb\xa9\x1b\x43\x00\x00\x00\x02\x00\x00\x20\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\x75\x23\x68\x60"
}

///|
fn patch_unused_extra() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x25\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x52\xfc\x1e\x77\x00\x00\x02\x60\x00\x60\x00\x08\x00\x20\x00\x30\xcc\x0c\xf5\x05\xce\x2e\xe4\x8a\x70\xa1\x20\xa5\xf8\x3c\xee\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xef\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\xed\x00\xde\x80\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xeb\xa9\x1b\x43\x00\x00\x00\x02\x00\x00\x20\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\x75\x23\x68\x60"
}

///|
fn patch_diff_crc() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x25\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x52\xfc\x1e\x77\x00\x00\x02\x60\x00\x60\x00\x08\x00\x20\x00\x30\xcc\x0c\xf5\x05\xce\x2e\xe4\x8a\x70\xa1\x20\xa5\xf8\x3c\xee\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xee\x68\x06\xf4\x00\x00\x00\x02\x00\x00\x40\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\xed\x00\xde\x80\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_extra_trailing() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x29\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x2b\xe4\x3c\xff\x00\x00\x00\x40\x00\x64\x08\x20\x00\x21\x8c\x83\x34\xd1\x09\x5d\x38\xbb\x92\x29\xc2\x84\x81\x5f\x21\xe7\xf8\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xeb\xa9\x1b\x43\x00\x00\x00\x02\x00\x00\x20\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\x75\x23\x68\x60\x21"
}

///|
fn patch_two_zero_ctrl() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2b\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x86\x7a\xae\x75\x00\x00\x00\xe0\x00\x60\x08\x00\x04\x20\x00\x30\xcd\x34\x12\x68\x36\x93\x27\x17\x72\x45\x38\x50\x90\x86\x7a\xae\x75\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\xeb\xa9\x1b\x43\x00\x00\x00\x02\x00\x00\x20\x20\x00\x21\x18\x46\x82\xee\x48\xa7\x0a\x12\x1d\x75\x23\x68\x60"
}

///|
fn patch_diff_short_multichunk() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2d\x00\x00\x00\x00\x00\x00\x00\x2d\x00\x00\x00\x00\x00\x00\x00\x88\x13\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x32\x1d\x16\xca\x00\x00\x03\x60\x40\x40\x00\x18\x00\x00\x40\x20\x00\x21\x21\xa0\xcd\x34\xd4\x17\x8b\xb9\x22\x9c\x28\x48\x19\x0e\x8b\x65\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x15\xa7\x69\x54\x00\x00\x08\x60\x00\xc0\x00\x40\x00\x00\x08\x20\x00\x30\xcc\x05\x53\x6a\x41\x47\x0f\x17\x72\x45\x38\x50\x90\x15\xa7\x69\x54\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
}

///|
fn patch_extra_short_multichunk() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2d\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x88\x13\x00\x00\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x76\x44\xde\x05\x00\x00\x00\x60\x40\x44\x10\x08\x00\x00\x40\x20\x00\x30\xcd\x00\x90\x12\xc0\x36\xe2\xee\x48\xa7\x0a\x12\x0e\xc8\x9b\xc0\xa0\x42\x5a\x68\x39\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x15\xa7\x69\x54\x00\x00\x08\x60\x00\xc0\x00\x40\x00\x00\x08\x20\x00\x30\xcc\x05\x53\x6a\x41\x47\x0f\x17\x72\x45\x38\x50\x90\x15\xa7\x69\x54"
}

///|
test "apply-stream-short-read-parity-and-multichunk" {
  let limits = @moonbsdiff.Limits::for_apply()
  // Upstream fixtures 0..12 including empty, block-move, periodic, seeded-random.
  let pairs = [
    (apply_fixture_0_old(), apply_fixture_0_new(), apply_fixture_0_patch()),
    (apply_fixture_1_old(), apply_fixture_1_new(), apply_fixture_1_patch()),
    (apply_fixture_2_old(), apply_fixture_2_new(), apply_fixture_2_patch()),
    (apply_fixture_3_old(), apply_fixture_3_new(), apply_fixture_3_patch()),
    (apply_fixture_4_old(), apply_fixture_4_new(), apply_fixture_4_patch()),
    (apply_fixture_5_old(), apply_fixture_5_new(), apply_fixture_5_patch()),
    (apply_fixture_6_old(), apply_fixture_6_new(), apply_fixture_6_patch()),
    (apply_fixture_7_old(), apply_fixture_7_new(), apply_fixture_7_patch()),
    (apply_fixture_8_old(), apply_fixture_8_new(), apply_fixture_8_patch()),
    (apply_fixture_9_old(), apply_fixture_9_new(), apply_fixture_9_patch()),
    (apply_fixture_10_old(), apply_fixture_10_new(), apply_fixture_10_patch()),
    (apply_fixture_11_old(), apply_fixture_11_new(), apply_fixture_11_patch()),
    (apply_fixture_12_old(), apply_fixture_12_new(), apply_fixture_12_patch()),
  ]
  for pair in pairs {
    let (old, expected_new, patch) = pair
    let expected_deep = @moonbsdiff.inspect_deep(patch, limits).unwrap()
    for step in [1, 7, 4096] {
      let stages : Array[@moonbsdiff.StreamApplyStage] = []
      let (out, info, _, _, checkpoints) = stream_test_run_chunked(
        old, patch, limits, step, step, stages,
      ).unwrap()
      assert_eq(out, expected_new)
      assert_eq(info, expected_deep)
      assert_eq(stages, [
        HeaderVerified(expected_deep.header),
        Restoring,
        Validating,
      ])
      assert_true(checkpoints >= 1)
    }
  }

  // Multi-chunk >4096 bytes for both diff and extra segments, tested with 7B/13B short reads.
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let prefix = stream_test_random(5000, 7001U)
  let middle = stream_test_random(5000, 7002U)
  let suffix = stream_test_random(5000, 7003U)
  let old_big = prefix + suffix
  let new_big = prefix + middle + suffix
  let patch_big = @moonbsdiff.diff(old_big, new_big, diff_limits).unwrap()
  let deep_big = @moonbsdiff.inspect_deep(patch_big, limits).unwrap()
  let stages_big : Array[@moonbsdiff.StreamApplyStage] = []
  let (restored_big, info_big, _, _, _) = stream_test_run_chunked(
    old_big, patch_big, limits, 13, 7, stages_big,
  ).unwrap()
  assert_eq(restored_big, new_big)
  assert_eq(info_big, deep_big)
  assert_eq(stages_big, [HeaderVerified(deep_big.header), Restoring, Validating])

  // Optional callbacks omitted works cleanly.
  let simple_out : Array[Byte] = []
  let simple_res : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[Unit],
  ] = @moonbsdiff.apply_stream(
    old_big.length().to_int64(),
    patch_big.length().to_int64(),
    limits,
    read_old_at=(offset, count) => {
      let s = offset.to_int()
      Ok(old_big[s:Int32::min(old_big.length(), s + count)].to_owned())
    },
    read_patch_at=(offset, count) => {
      let s = offset.to_int()
      Ok(patch_big[s:Int32::min(patch_big.length(), s + count)].to_owned())
    },
    write_output=chunk => {
      for b in chunk {
        simple_out.push(b)
      }
      Ok(())
    },
  )
  let simple_info = simple_res.unwrap()
  assert_eq(Bytes::from_array(simple_out), new_big)
  assert_eq(simple_info, deep_big)
}

///|
test "apply-stream-int64-min-and-signed-windowing" {
  let limits = @moonbsdiff.Limits::for_apply()

  // Int64.min cursor must never negate Int64.min or call read_old_at when out of range.
  let min_patch = patch_int64_min()
  let old_abcd = b"ABCD"
  let min_stages : Array[@moonbsdiff.StreamApplyStage] = []
  let (min_out, _, min_old_calls, _, _) = stream_test_run_chunked(
    old_abcd, min_patch, limits, 1, 7, min_stages,
  ).unwrap()
  assert_eq(min_out, b"XYZW")
  assert_eq(min_old_calls, 0)
  assert_eq(@moonbsdiff.apply(old_abcd, min_patch, limits), Ok(b"XYZW"))

  // Negative cursor straddling 0 across [0, 2): read_old_at only requested for [0, 2).
  let ob_patch = patch_outside_both()
  let ob_old = b"AB"
  let ob_reads : Array[(Int64, Int32)] = []
  let ob_out : Array[Byte] = []
  let ob_res : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[Unit],
  ] = @moonbsdiff.apply_stream(
    2L,
    ob_patch.length().to_int64(),
    limits,
    read_old_at=(offset, _count) => {
      ob_reads.push((offset, _count))
      let s = offset.to_int()
      Ok(ob_old[s:s + 1].to_owned())
    },
    read_patch_at=(offset, count) => {
      let s = offset.to_int()
      Ok(ob_patch[s:Int32::min(ob_patch.length(), s + count)].to_owned())
    },
    write_output=chunk => {
      for b in chunk {
        ob_out.push(b)
      }
      Ok(())
    },
  )
  ignore(ob_res.unwrap())
  assert_eq(Bytes::from_array(ob_out), b"\x01\x02AB\x05")
  assert_eq(ob_reads, [(0L, 2), (1L, 1)])
  assert_eq(@moonbsdiff.apply(ob_old, ob_patch, limits), Ok(b"\x01\x02AB\x05"))

  // Cursor >= old_size: read_old_at must never be called.
  let oh_patch = patch_outside_high()
  let (_, _, oh_old_calls, _, _) = stream_test_run_chunked(
    ob_old,
    oh_patch,
    limits,
    4096,
    4096,
    [],
  ).unwrap()
  assert_eq(oh_old_calls, 0)
  assert_eq(@moonbsdiff.apply(ob_old, oh_patch, limits), Ok(b"XYZ"))
}

///|
test "apply-stream-callback-errors-and-stages" {
  let limits = @moonbsdiff.Limits::for_apply()
  let old = b"MoonBSDiff"
  let new = b"MoonBSDiff-stream!"
  let patch = @moonbsdiff.diff(old, new, @moonbsdiff.Limits::for_diff()).unwrap()
  let info = @moonbsdiff.inspect_header(patch, limits.max_patch_bytes).unwrap()

  // Fail from on_stage at HeaderVerified, Restoring, Validating.
  for target_stage in [0, 1, 2] {
    let mut stage_idx = 0
    let mut writes = 0
    let res = @moonbsdiff.apply_stream(
      old.length().to_int64(),
      patch.length().to_int64(),
      limits,
      read_old_at=(o, c) => {
        Ok(old[o.to_int():Int32::min(old.length(), o.to_int() + c)].to_owned())
      },
      read_patch_at=(o, c) => {
        Ok(
          patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
        )
      },
      write_output=_ => {
        writes += 1
        Ok(())
      },
      on_stage=_ => {
        let cur = stage_idx
        stage_idx += 1
        if cur == target_stage {
          Err("stage_fail_\{cur}")
        } else {
          Ok(())
        }
      },
    )
    assert_eq(res, Err(Io("stage_fail_\{target_stage}")))
    if target_stage < 2 {
      assert_eq(writes, 0)
    }
  }

  // Fail from read_patch_at during header read, control open, diff read, extra read.
  for fail_offset in [0L, info.control_start, info.diff_start, info.extra_start] {
    let res = @moonbsdiff.apply_stream(
      old.length().to_int64(),
      patch.length().to_int64(),
      limits,
      read_old_at=(o, c) => {
        Ok(old[o.to_int():Int32::min(old.length(), o.to_int() + c)].to_owned())
      },
      read_patch_at=(o, c) => {
        if o <= fail_offset && fail_offset < o + c.to_int64() {
          Err("patch_io_\{fail_offset}")
        } else {
          Ok(
            patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
          )
        }
      },
      write_output=_ => Ok(()),
    )
    assert_eq(res, Err(Io("patch_io_\{fail_offset}")))
  }

  // Fail from read_patch_at during Validating trailing EOF check (1B reads).
  let mut saw_validating = false
  let res_validating_patch_err = @moonbsdiff.apply_stream(
    old.length().to_int64(),
    patch.length().to_int64(),
    limits,
    read_old_at=(o, c) => {
      Ok(old[o.to_int():Int32::min(old.length(), o.to_int() + c)].to_owned())
    },
    read_patch_at=(o, c) => {
      if saw_validating {
        Err("validating_patch_io")
      } else {
        let take = Int32::min(1, c)
        Ok(
          patch[o.to_int():Int32::min(patch.length(), o.to_int() + take)].to_owned(),
        )
      }
    },
    write_output=_ => Ok(()),
    on_stage=st => {
      if st == Validating {
        saw_validating = true
      }
      Ok(())
    },
  )
  assert_eq(res_validating_patch_err, Err(Io("validating_patch_io")))

  // Fail from read_old_at, write_output, and checkpoint.
  let res_old = @moonbsdiff.apply_stream(
    old.length().to_int64(),
    patch.length().to_int64(),
    limits,
    read_old_at=(_, _) => Err("old_io"),
    read_patch_at=(o, c) => {
      Ok(
        patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
      )
    },
    write_output=_ => Ok(()),
  )
  assert_eq(res_old, Err(Io("old_io")))

  let res_write = @moonbsdiff.apply_stream(
    old.length().to_int64(),
    patch.length().to_int64(),
    limits,
    read_old_at=(o, c) => {
      Ok(old[o.to_int():Int32::min(old.length(), o.to_int() + c)].to_owned())
    },
    read_patch_at=(o, c) => {
      Ok(
        patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
      )
    },
    write_output=_ => Err("write_io"),
  )
  assert_eq(res_write, Err(Io("write_io")))

  for fail_cp in [1, 2, 3, 4, 5, 6] {
    let mut cp = 0
    let res_cp = @moonbsdiff.apply_stream(
      old.length().to_int64(),
      patch.length().to_int64(),
      limits,
      read_old_at=(o, c) => {
        Ok(old[o.to_int():Int32::min(old.length(), o.to_int() + c)].to_owned())
      },
      read_patch_at=(o, c) => {
        Ok(
          patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
        )
      },
      write_output=_ => Ok(()),
      checkpoint=() => {
        cp += 1
        if cp == fail_cp {
          Err("cancelled_\{fail_cp}")
        } else {
          Ok(())
        }
      },
    )
    assert_eq(res_cp, Err(Io("cancelled_\{fail_cp}")))
  }
}

///|
test "apply-stream-callback-protocol-violations" {
  let limits = @moonbsdiff.Limits::for_apply()
  let old = b"ABCD"
  let patch = @moonbsdiff.diff(old, b"ABXD", @moonbsdiff.Limits::for_diff()).unwrap()

  // Premature 0-byte read from read_patch_at in header.
  stream_test_assert_bsdiff(
    @moonbsdiff.apply_stream(
      4L,
      patch.length().to_int64(),
      limits,
      read_old_at=(_, _) => Ok(b""),
      read_patch_at=(_, _) => Ok(b""),
      write_output=_ => Ok(()),
    ),
    TruncatedData,
    Header,
    None,
  )

  // Oversized read from read_patch_at in header.
  stream_test_assert_bsdiff(
    @moonbsdiff.apply_stream(
      4L,
      patch.length().to_int64(),
      limits,
      read_old_at=(_, _) => Ok(b""),
      read_patch_at=(_, want) => {
        Ok(Bytes::from_array(Array::make(want + 1, b'\x00')))
      },
      write_output=_ => Ok(()),
    ),
    InvalidField,
    Header,
    Some("patch_read_length"),
  )

  // Premature 0-byte read from read_patch_at in control stream.
  stream_test_assert_bsdiff(
    @moonbsdiff.apply_stream(
      4L,
      patch.length().to_int64(),
      limits,
      read_old_at=(_, _) => Ok(b""),
      read_patch_at=(offset, want) => {
        if offset >= 32L {
          Ok(b"")
        } else {
          Ok(patch[offset.to_int():offset.to_int() + want].to_owned())
        }
      },
      write_output=_ => Ok(()),
    ),
    TruncatedData,
    Control,
    None,
  )

  // Oversized read from read_patch_at in control stream.
  stream_test_assert_bsdiff(
    @moonbsdiff.apply_stream(
      4L,
      patch.length().to_int64(),
      limits,
      read_old_at=(_, _) => Ok(b""),
      read_patch_at=(offset, want) => {
        if offset >= 32L {
          Ok(Bytes::from_array(Array::make(want + 1, b'\x00')))
        } else {
          Ok(patch[offset.to_int():offset.to_int() + want].to_owned())
        }
      },
      write_output=_ => Ok(()),
    ),
    InvalidField,
    Control,
    Some("patch_read_length"),
  )

  // Premature 0-byte read from read_old_at.
  stream_test_assert_bsdiff(
    @moonbsdiff.apply_stream(
      4L,
      patch.length().to_int64(),
      limits,
      read_old_at=(_, _) => Ok(b""),
      read_patch_at=(o, c) => {
        Ok(
          patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
        )
      },
      write_output=_ => Ok(()),
    ),
    TruncatedData,
    Diff,
    Some("old_read_eof"),
  )

  // Partial read followed by EOF from read_old_at.
  let patch_full_diff = @moonbsdiff.diff(
    old,
    old,
    @moonbsdiff.Limits::for_diff(),
  ).unwrap()
  let partial_old_reads : Array[(Int64, Int32)] = []
  let partial_old_res : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[String],
  ] = @moonbsdiff.apply_stream(
    4L,
    patch_full_diff.length().to_int64(),
    limits,
    read_old_at=(offset, count) => {
      partial_old_reads.push((offset, count))
      if partial_old_reads.length() == 1 {
        Ok(b"AB")
      } else {
        Ok(b"")
      }
    },
    read_patch_at=(o, c) => {
      Ok(
        patch_full_diff[o.to_int():Int32::min(
          patch_full_diff.length(),
          o.to_int() + c,
        )].to_owned(),
      )
    },
    write_output=_ => Ok(()),
  )
  match partial_old_res {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, TruncatedData)
      assert_eq(e.stage, Diff)
      assert_eq(e.field, Some("old_read_eof"))
      assert_eq(e.offset, Some(2L))
      assert_eq(e.value, Some(2L))
      assert_eq(e.limit, Some(4L))
    }
    _ => abort("expected partial-then-EOF old read failure")
  }
  assert_eq(partial_old_reads, [(0L, 4), (2L, 2)])

  // Oversized read from read_old_at.
  stream_test_assert_bsdiff(
    @moonbsdiff.apply_stream(
      4L,
      patch.length().to_int64(),
      limits,
      read_old_at=(_, need) => {
        Ok(Bytes::from_array(Array::make(need + 1, b'\x00')))
      },
      read_patch_at=(o, c) => {
        Ok(
          patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
        )
      },
      write_output=_ => Ok(()),
    ),
    InvalidField,
    Diff,
    Some("old_read_length"),
  )
}

///|
test "apply-stream-limits-and-corrupt-streams" {
  let limits = @moonbsdiff.Limits::for_apply()
  let patch = apply_fixture_13_patch()

  // Limits, old_size, and patch_size must be validated BEFORE any callback.
  let mut callbacks = 0
  let no_callbacks = fn(
    old_size : Int64,
    patch_size : Int64,
    bad : @moonbsdiff.Limits,
  ) -> Result[@moonbsdiff.DeepPatchInfo, @moonbsdiff.StreamApplyError[String]] {
    @moonbsdiff.apply_stream(
      old_size,
      patch_size,
      bad,
      read_old_at=(_, _) => {
        callbacks += 1
        Ok(b"")
      },
      read_patch_at=(_, _) => {
        callbacks += 1
        Ok(b"")
      },
      write_output=_ => {
        callbacks += 1
        Ok(())
      },
      on_stage=_ => {
        callbacks += 1
        Ok(())
      },
      checkpoint=() => {
        callbacks += 1
        Ok(())
      },
    )
  }

  stream_test_assert_bsdiff(
    no_callbacks(0L, 74L, { ..limits, max_old_bytes: 0L, }),
    InvalidConfiguration,
    Configuration,
    Some("max_old_bytes"),
  )
  stream_test_assert_bsdiff(
    no_callbacks(-1L, 74L, limits),
    InvalidField,
    Header,
    Some("old_size"),
  )
  stream_test_assert_bsdiff(
    no_callbacks(11L, 74L, { ..limits, max_old_bytes: 10L, }),
    ResourceLimitExceeded,
    Header,
    Some("max_old_bytes"),
  )
  stream_test_assert_bsdiff(
    no_callbacks(0L, -1L, limits),
    InvalidField,
    Header,
    Some("patch_bytes"),
  )
  stream_test_assert_bsdiff(
    no_callbacks(0L, 100L, { ..limits, max_patch_bytes: 99L, }),
    ResourceLimitExceeded,
    Header,
    Some("max_patch_bytes"),
  )
  assert_eq(callbacks, 0)

  // patch_size == 0L must report TruncatedData at Header without calling read_patch_at.
  let mut zero_patch_calls = 0
  let zero_res : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[Unit],
  ] = @moonbsdiff.apply_stream(
    0L,
    0L,
    limits,
    read_old_at=(_, _) => Ok(b""),
    read_patch_at=(_, _) => {
      zero_patch_calls += 1
      Ok(b"")
    },
    write_output=_ => Ok(()),
  )
  match zero_res {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, TruncatedData)
      assert_eq(e.stage, Header)
      assert_eq(e.offset, Some(0L))
      assert_eq(e.limit, Some(32L))
    }
    _ => abort("expected truncated header on patch_size == 0L")
  }
  assert_eq(zero_patch_calls, 0)

  // patch_size < 32 must report TruncatedData at Header with offset = patch_size.
  let short_res : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[Unit],
  ] = @moonbsdiff.apply_stream(
    0L,
    10L,
    limits,
    read_old_at=(_, _) => Ok(b""),
    read_patch_at=(o, c) => {
      Ok(patch[o.to_int():Int32::min(10, o.to_int() + c)].to_owned())
    },
    write_output=_ => Ok(()),
  )
  match short_res {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, TruncatedData)
      assert_eq(e.stage, Header)
      assert_eq(e.offset, Some(10L))
      assert_eq(e.limit, Some(32L))
    }
    _ => abort("expected truncated header")
  }

  // max_output_bytes checked before max_new_bytes, both at offset Some(24L).
  let mut stages_called = 0
  let both_over = @moonbsdiff.apply_stream(
    1L,
    patch.length().to_int64(),
    { ..limits, max_output_bytes: 0L, max_new_bytes: 0L, }, // invalid if 0
    read_old_at=(_, _) => Ok(b"\xff"),
    read_patch_at=(o, c) => {
      Ok(
        patch[o.to_int():Int32::min(patch.length(), o.to_int() + c)].to_owned(),
      )
    },
    write_output=_ => Ok(()),
  )
  stream_test_assert_bsdiff(
    both_over,
    InvalidConfiguration,
    Configuration,
    Some("max_new_bytes"),
  )
  let out_first : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[Unit],
  ] = @moonbsdiff.apply_stream(
    1L,
    apply_fixture_4_patch().length().to_int64(),
    { ..limits, max_output_bytes: 5L, max_new_bytes: 5L, },
    read_old_at=(_, _) => Ok(b""),
    read_patch_at=(o, c) => {
      let p = apply_fixture_4_patch()
      Ok(p[o.to_int():Int32::min(p.length(), o.to_int() + c)].to_owned())
    },
    write_output=_ => Ok(()),
    on_stage=_ => {
      stages_called += 1
      Ok(())
    },
  )
  match out_first {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Header)
      assert_eq(e.offset, Some(24L))
      assert_eq(e.field, Some("max_output_bytes"))
    }
    _ => abort("expected max_output_bytes")
  }
  let new_second : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[Unit],
  ] = @moonbsdiff.apply_stream(
    1L,
    apply_fixture_4_patch().length().to_int64(),
    { ..limits, max_new_bytes: 5L, },
    read_old_at=(_, _) => Ok(b""),
    read_patch_at=(o, c) => {
      let p = apply_fixture_4_patch()
      Ok(p[o.to_int():Int32::min(p.length(), o.to_int() + c)].to_owned())
    },
    write_output=_ => Ok(()),
    on_stage=_ => {
      stages_called += 1
      Ok(())
    },
  )
  match new_second {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Header)
      assert_eq(e.offset, Some(24L))
      assert_eq(e.field, Some("max_new_bytes"))
    }
    _ => abort("expected max_new_bytes")
  }
  assert_eq(stages_called, 0)

  // Crafted malformed/corrupt control, diff, extra, CRC, trailing, and budget errors.
  let run_bad = fn(
    p : Bytes,
    custom_limits : @moonbsdiff.Limits,
  ) -> Result[@moonbsdiff.DeepPatchInfo, @moonbsdiff.StreamApplyError[String]] {
    @moonbsdiff.apply_stream(
      0L,
      p.length().to_int64(),
      custom_limits,
      read_old_at=(_, _) => Ok(b""),
      read_patch_at=(o, c) => {
        Ok(p[o.to_int():Int32::min(p.length(), o.to_int() + c)].to_owned())
      },
      write_output=_ => Ok(()),
    )
  }

  stream_test_assert_bsdiff(
    run_bad(patch_neg_x(), limits),
    InvalidField,
    Control,
    Some("diff_length"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_neg_y(), limits),
    InvalidField,
    Control,
    Some("extra_length"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_oob_x(), limits),
    OutputOutOfBounds,
    Control,
    Some("diff_length"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_oob_y(), limits),
    OutputOutOfBounds,
    Control,
    Some("extra_length"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_ovf_x(), limits),
    IntegerOverflow,
    Control,
    Some("old_plus_x"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_ovf_z(), limits),
    IntegerOverflow,
    Control,
    Some("old_plus_z"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_udf_z(), limits),
    IntegerOverflow,
    Control,
    Some("old_plus_z"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_ctrl_short(), limits),
    TruncatedData,
    Control,
    Some("control_triple_bytes"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_diff_short(), limits),
    TruncatedData,
    Diff,
    Some("diff_decoded_consumption"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_extra_short(), limits),
    TruncatedData,
    Extra,
    Some("extra_decoded_consumption"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_unused_ctrl(), limits),
    InvalidField,
    Control,
    Some("unconsumed_control"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_unused_diff(), limits),
    InvalidField,
    Diff,
    Some("unconsumed_diff"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_unused_extra(), limits),
    InvalidField,
    Extra,
    Some("unconsumed_extra"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_diff_crc(), limits),
    DecompressionFailed,
    Diff,
    Some("crc"),
  )
  stream_test_assert_bsdiff(
    run_bad(patch_extra_trailing(), limits),
    InvalidField,
    Extra,
    Some("trailing data after single bzip2 stream"),
  )

  // Multi-chunk truncated diff (x=5000, diff=4100B) and extra (y=5000, extra=4100B)
  // must report cumulative expected/actual bytes matching apply().
  let mc_diff = patch_diff_short_multichunk()
  let mc_diff_apply_err = match @moonbsdiff.apply(b"", mc_diff, limits) {
    Ok(_) => abort("expected apply multi-chunk diff truncation")
    Err(e) => e
  }
  match run_bad(mc_diff, limits) {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, TruncatedData)
      assert_eq(e.stage, Diff)
      assert_eq(e.field, Some("diff_decoded_consumption"))
      assert_eq(e.value, Some(5000L))
      assert_eq(e.limit, Some(4100L))
      assert_eq(e, mc_diff_apply_err)
    }
    _ => abort("expected stream multi-chunk diff truncation")
  }

  let mc_extra = patch_extra_short_multichunk()
  let mc_extra_apply_err = match @moonbsdiff.apply(b"", mc_extra, limits) {
    Ok(_) => abort("expected apply multi-chunk extra truncation")
    Err(e) => e
  }
  match run_bad(mc_extra, limits) {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, TruncatedData)
      assert_eq(e.stage, Extra)
      assert_eq(e.field, Some("extra_decoded_consumption"))
      assert_eq(e.value, Some(5000L))
      assert_eq(e.limit, Some(4100L))
      assert_eq(e, mc_extra_apply_err)
    }
    _ => abort("expected stream multi-chunk extra truncation")
  }

  // max_control_instructions limit (cap and explicit loop check) + shared budget.
  let two_ctrl = patch_two_zero_ctrl()
  assert_true(run_bad(two_ctrl, limits) is Ok(_))
  stream_test_assert_bsdiff(
    run_bad(two_ctrl, { ..limits, max_control_instructions: 1L, }),
    ResourceLimitExceeded,
    Control,
    Some("block_output_bytes"),
  )

  // Valid 2-control patch where triple 1 finishes cleanly on a 24B RLE boundary
  // and produces < new_bytes, hitting the explicit control_count >= max_control_instructions check.
  let mc_pre = stream_test_random(32, 8001U)
  let mc_suf = stream_test_random(32, 8002U)
  let mc_old = mc_pre + mc_suf
  let mc_new = mc_pre + b"X" + mc_suf
  let mc_patch = @moonbsdiff.diff(
    mc_old,
    mc_new,
    @moonbsdiff.Limits::for_diff(),
  ).unwrap()
  assert_eq(
    @moonbsdiff.inspect_deep(mc_patch, limits).unwrap().control_count,
    2L,
  )
  let explicit_ctrl_res : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[String],
  ] = @moonbsdiff.apply_stream(
    mc_old.length().to_int64(),
    mc_patch.length().to_int64(),
    { ..limits, max_control_instructions: 1L, },
    read_old_at=(o, c) => {
      Ok(
        mc_old[o.to_int():Int32::min(mc_old.length(), o.to_int() + c)].to_owned(),
      )
    },
    read_patch_at=(o, c) => {
      Ok(
        mc_patch[o.to_int():Int32::min(mc_patch.length(), o.to_int() + c)].to_owned(),
      )
    },
    write_output=_ => Ok(()),
  )
  match explicit_ctrl_res {
    Err(Bsdiff(e)) => {
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Control)
      assert_eq(e.field, Some("max_control_instructions"))
      assert_eq(e.value, Some(2L))
      assert_eq(e.limit, Some(1L))
    }
    _ => abort("expected explicit max_control_instructions failure")
  }

  let exact_budget = { ..limits, max_decompressed_bytes: 49L, }
  assert_true(run_bad(two_ctrl, exact_budget) is Ok(_))
  stream_test_assert_bsdiff(
    run_bad(two_ctrl, { ..limits, max_decompressed_bytes: 48L, }),
    ResourceLimitExceeded,
    Extra,
    Some("decompressed_remaining"),
  )

  // 173-byte BZh9 BWT bomb must fail closed before inverse-BWT in apply_stream
  // with zero output bytes written and exact error parity with apply().
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
  let tight_bomb : @moonbsdiff.Limits = {
    ..limits,
    max_patch_bytes: 256L,
    max_new_bytes: 2L,
    max_output_bytes: 2L,
    max_decompressed_bytes: 26L,
    max_control_instructions: 1L,
  }
  let mut bomb_writes = 0
  let bomb_stream_res : Result[
    @moonbsdiff.DeepPatchInfo,
    @moonbsdiff.StreamApplyError[String],
  ] = @moonbsdiff.apply_stream(
    2L,
    bwt_bomb_patch.length().to_int64(),
    tight_bomb,
    read_old_at=(o, c) => {
      let old = b"AB"
      Ok(old[o.to_int():Int32::min(old.length(), o.to_int() + c)].to_owned())
    },
    read_patch_at=(o, c) => {
      Ok(
        bwt_bomb_patch[o.to_int():Int32::min(
          bwt_bomb_patch.length(),
          o.to_int() + c,
        )].to_owned(),
      )
    },
    write_output=_ => {
      bomb_writes += 1
      Ok(())
    },
  )
  let bomb_apply_err = match
    @moonbsdiff.apply(b"AB", bwt_bomb_patch, tight_bomb) {
    Ok(_) => abort("expected apply to reject BZh9 BWT bomb")
    Err(e) => e
  }
  match bomb_stream_res {
    Err(Bsdiff(e)) => {
      assert_eq(e, bomb_apply_err)
      assert_eq(e.kind, ResourceLimitExceeded)
      assert_eq(e.stage, Control)
    }
    _ => abort("expected apply_stream to reject BZh9 BWT bomb")
  }
  assert_eq(bomb_writes, 0)
}
