///|
priv struct StreamPresetFixture {
  old_bytes : Bytes
  new_bytes : Bytes
  patch_bytes : Bytes
  target_sha256 : String
}

///|
let stream_preset_cache : Map[String, StreamPresetFixture] = Map([])

///|
fn get_stream_fixture(preset_name : String) -> StreamPresetFixture {
  let key = match preset_name {
    "mixed_insert_24k" => "mixed_insert_24k"
    "reorder_seek_16k" => "reorder_seek_16k"
    _ => "firmware_20k"
  }
  match stream_preset_cache.get(key) {
    Some(cached) => return cached
    None => ()
  }
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let (old_bytes, new_bytes) = match key {
    "mixed_insert_24k" => {
      let pre = Bytes::from_array(structured_firmware_image(10240, 0x3101U))
      let suf = Bytes::from_array(structured_firmware_image(10240, 0x3102U))
      let ins = prng_bytes(4096, 0x3103U)
      (pre + suf, pre + ins + suf)
    }
    "reorder_seek_16k" => {
      let b0 = Bytes::from_array(structured_firmware_image(4096, 0x4101U))
      let b1 = Bytes::from_array(structured_firmware_image(4096, 0x4102U))
      let b2 = Bytes::from_array(structured_firmware_image(4096, 0x4103U))
      let b3 = Bytes::from_array(structured_firmware_image(4096, 0x4104U))
      (b0 + b1 + b2 + b3, b3 + b1 + b0 + b2)
    }
    _ => {
      let old_arr = structured_firmware_image(20480, 0x2101U)
      let a1 = mutate_slice(old_arr, 3000, prng_bytes(64, 0x2102U))
      let a2 = mutate_slice(a1, 10500, prng_bytes(80, 0x2103U))
      let a3 = mutate_slice(a2, 17500, b"STREAM-RESTORE-0.7.0-OK!!")
      (Bytes::from_array(old_arr), Bytes::from_array(a3))
    }
  }
  let patch_bytes = @moonbsdiff.diff(old_bytes, new_bytes, diff_limits).unwrap()
  let target_sha256 = @manifest_support.sha256_hex(new_bytes)
  let fixture : StreamPresetFixture = {
    old_bytes,
    new_bytes,
    patch_bytes,
    target_sha256,
  }
  stream_preset_cache[key] = fixture
  fixture
}

///|
fn slice_bytes_clamped(src : Bytes, offset : Int64, count : Int32) -> Bytes {
  let len = src.length().to_int64()
  if offset < 0L || offset >= len || count <= 0 {
    return b""
  }
  let start = offset.to_int()
  let avail = (len - offset).to_int()
  let take = if count < avail { count } else { avail }
  src[start:start + take].to_owned()
}

///|
fn stream_error_json(
  preset_val : @json.Json,
  abort_val : Int32,
  error_type : String,
  detail : String,
) -> String {
  j_obj({
    "ok": j_bool(false),
    "preset_name": preset_val,
    "abort_after_chunks": j_int(abort_val),
    "aborted": j_bool(false),
    "final_delivered": j_bool(false),
    "sha256_verified": j_bool(false),
    "old_bytes": j_i64(0L),
    "patch_bytes": j_i64(0L),
    "target_bytes": j_i64(0L),
    "written_bytes": j_i64(0L),
    "buffer_ceiling_bytes": j_int(4096),
    "max_chunk_bytes": j_int(0),
    "target_sha256": j_null(),
    "restored_sha256": j_null(),
    "counters": j_obj({
      "read_old_calls": j_int(0),
      "read_old_bytes": j_i64(0L),
      "read_patch_calls": j_int(0),
      "read_patch_bytes": j_i64(0L),
      "write_output_calls": j_int(0),
      "write_output_bytes": j_i64(0L),
      "checkpoint_calls": j_int(0),
    }),
    "stages": j_arr([]),
    "chunks": j_arr([]),
    "events": j_arr([]),
    "deep_info": j_null(),
    "error": j_obj({
      "kind": j_str(error_type),
      "error_type": j_str(error_type),
      "detail": j_str(detail),
      "bsdiff_error": j_null(),
      "raw": j_str(detail),
    }),
  }).stringify()
}

///|
fn trace_stream_apply_impl(
  preset_name : String,
  abort_after_chunks : Double,
) -> String {
  if !js_is_string(preset_name) {
    return stream_error_json(
      j_null(),
      0,
      "InvalidRequest",
      "preset_name must be a string",
    )
  }
  if !js_is_number(abort_after_chunks) ||
    abort_after_chunks != abort_after_chunks ||
    abort_after_chunks - abort_after_chunks != 0.0 ||
    abort_after_chunks < -2147483648.0 ||
    abort_after_chunks > 2147483647.0 ||
    abort_after_chunks.floor() != abort_after_chunks {
    return stream_error_json(
      j_str(preset_name),
      0,
      "InvalidRequest",
      "abort_after_chunks must be a finite 32-bit integer",
    )
  }
  let abort_i32 = abort_after_chunks.to_int()
  let effective_abort = if abort_i32 < 0 { 0 } else { abort_i32 }
  let resolved_preset = match preset_name {
    "firmware_20k" => "firmware_20k"
    "mixed_insert_24k" => "mixed_insert_24k"
    "reorder_seek_16k" => "reorder_seek_16k"
    _ =>
      return stream_error_json(
        j_str(preset_name),
        effective_abort,
        "UnknownPreset",
        "unknown stream preset: " + preset_name,
      )
  }
  let fixture = get_stream_fixture(resolved_preset)
  let old_bytes = fixture.old_bytes
  let patch_bytes = fixture.patch_bytes
  let limits = @moonbsdiff.Limits::for_apply()

  let events : Array[@json.Json] = []
  let stages : Array[@json.Json] = []
  let chunks : Array[@json.Json] = []
  let restored_buf : Array[Byte] = []

  let mut event_seq = 0
  let mut read_old_calls = 0
  let mut read_old_bytes = 0L
  let mut read_patch_calls = 0
  let mut read_patch_bytes = 0L
  let mut write_output_calls = 0
  let mut written_bytes = 0L
  let mut checkpoint_calls = 0
  let mut max_chunk_bytes = 0

  let push_event = fn(
    kind : String,
    detail : String,
    offset : Int64?,
    length : Int64?,
  ) -> Int32 {
    let idx = event_seq
    event_seq = event_seq + 1
    if events.length() < 512 {
      events.push(
        j_obj({
          "index": j_int(idx),
          "kind": j_str(kind),
          "detail": j_str(detail),
          "offset": j_opt_i64(offset),
          "length": j_opt_i64(length),
          "cumulative_written": j_i64(written_bytes),
        }),
      )
    }
    idx
  }

  let result = @moonbsdiff.apply_stream(
    old_bytes.length().to_int64(),
    patch_bytes.length().to_int64(),
    limits,
    read_old_at=fn(offset, count) {
      let chunk = slice_bytes_clamped(old_bytes, offset, count)
      read_old_calls = read_old_calls + 1
      read_old_bytes = read_old_bytes + chunk.length().to_int64()
      let _ = push_event(
        "read_old_at",
        "offset=\{offset} len=\{chunk.length()}",
        Some(offset),
        Some(chunk.length().to_int64()),
      )
      Ok(chunk)
    },
    read_patch_at=fn(offset, count) {
      let chunk = slice_bytes_clamped(patch_bytes, offset, count)
      read_patch_calls = read_patch_calls + 1
      read_patch_bytes = read_patch_bytes + chunk.length().to_int64()
      let _ = push_event(
        "read_patch_at",
        "offset=\{offset} len=\{chunk.length()}",
        Some(offset),
        Some(chunk.length().to_int64()),
      )
      Ok(chunk)
    },
    write_output=fn(chunk) {
      let out_offset = written_bytes
      let clen = chunk.length()
      for b in chunk {
        restored_buf.push(b)
      }
      write_output_calls = write_output_calls + 1
      written_bytes = written_bytes + clen.to_int64()
      if clen > max_chunk_bytes {
        max_chunk_bytes = clen
      }
      let ev_idx = push_event(
        "write_output",
        "chunk #\{write_output_calls} (\{clen} B @ \{out_offset})",
        Some(out_offset),
        Some(clen.to_int64()),
      )
      chunks.push(
        j_obj({
          "chunk_index": j_int(write_output_calls),
          "event_index": j_int(ev_idx),
          "output_offset": j_i64(out_offset),
          "length": j_int(clen),
          "cumulative_bytes": j_i64(written_bytes),
          "old_reads_so_far": j_int(read_old_calls),
          "patch_reads_so_far": j_int(read_patch_calls),
        }),
      )
      Ok(())
    },
    on_stage=fn(stage) {
      match stage {
        @moonbsdiff.StreamApplyStage::HeaderVerified(info) => {
          let ev_idx = push_event(
            "stage",
            "HeaderVerified (new=\{info.new_bytes} B, patch=\{info.patch_bytes} B)",
            Some(0L),
            Some(32L),
          )
          stages.push(
            j_obj({
              "stage": j_str("HeaderVerified"),
              "event_index": j_int(ev_idx),
              "new_bytes": j_i64(info.new_bytes),
              "patch_bytes": j_i64(info.patch_bytes),
            }),
          )
        }
        @moonbsdiff.StreamApplyStage::Restoring => {
          let ev_idx = push_event("stage", "Restoring", None, None)
          stages.push(
            j_obj({
              "stage": j_str("Restoring"),
              "event_index": j_int(ev_idx),
              "new_bytes": j_null(),
              "patch_bytes": j_null(),
            }),
          )
        }
        @moonbsdiff.StreamApplyStage::Validating => {
          let ev_idx = push_event("stage", "Validating", None, None)
          stages.push(
            j_obj({
              "stage": j_str("Validating"),
              "event_index": j_int(ev_idx),
              "new_bytes": j_null(),
              "patch_bytes": j_null(),
            }),
          )
        }
      }
      Ok(())
    },
    checkpoint=fn() {
      checkpoint_calls = checkpoint_calls + 1
      if effective_abort > 0 && write_output_calls >= effective_abort {
        let _ = push_event(
          "checkpoint_abort",
          "cancelled_by_user after \{write_output_calls} chunks",
          Some(written_bytes),
          None,
        )
        Err("cancelled_by_user")
      } else {
        Ok(())
      }
    },
  )

  let counters_json = j_obj({
    "read_old_calls": j_int(read_old_calls),
    "read_old_bytes": j_i64(read_old_bytes),
    "read_patch_calls": j_int(read_patch_calls),
    "read_patch_bytes": j_i64(read_patch_bytes),
    "write_output_calls": j_int(write_output_calls),
    "write_output_bytes": j_i64(written_bytes),
    "checkpoint_calls": j_int(checkpoint_calls),
  })

  match result {
    Ok(deep) => {
      let restored_bytes = Bytes::from_array(restored_buf)
      let restored_sha = @manifest_support.sha256_hex(restored_bytes)
      let verified = restored_sha == fixture.target_sha256 &&
        restored_bytes == fixture.new_bytes
      j_obj({
        "ok": j_bool(verified),
        "preset_name": j_str(resolved_preset),
        "abort_after_chunks": j_int(effective_abort),
        "aborted": j_bool(false),
        "final_delivered": j_bool(verified),
        "sha256_verified": j_bool(verified),
        "old_bytes": j_i64(old_bytes.length().to_int64()),
        "patch_bytes": j_i64(patch_bytes.length().to_int64()),
        "target_bytes": j_i64(fixture.new_bytes.length().to_int64()),
        "written_bytes": j_i64(written_bytes),
        "buffer_ceiling_bytes": j_int(4096),
        "max_chunk_bytes": j_int(max_chunk_bytes),
        "target_sha256": j_str(fixture.target_sha256),
        "restored_sha256": j_str(restored_sha),
        "counters": counters_json,
        "stages": j_arr(stages),
        "chunks": j_arr(chunks),
        "events": j_arr(events),
        "deep_info": j_obj({
          "control_count": j_i64(deep.control_count),
          "diff_bytes": j_i64(deep.diff_bytes),
          "extra_bytes": j_i64(deep.extra_bytes),
          "expanded_bytes": j_i64(deep.expanded_bytes),
          "patch_bytes": j_i64(deep.header.patch_bytes),
          "new_bytes": j_i64(deep.header.new_bytes),
        }),
        "error": j_null(),
      }).stringify()
    }
    Err(err) => {
      let (err_type, err_detail, bsdiff_json) = match err {
        @moonbsdiff.StreamApplyError::Io(reason) => ("Io", reason, j_null())
        @moonbsdiff.StreamApplyError::Bsdiff(be) =>
          ("Bsdiff", error_kind_name(be.kind), bsdiff_error_json(be))
      }
      j_obj({
        "ok": j_bool(false),
        "preset_name": j_str(resolved_preset),
        "abort_after_chunks": j_int(effective_abort),
        "aborted": j_bool(err_type == "Io"),
        "final_delivered": j_bool(false),
        "sha256_verified": j_bool(false),
        "old_bytes": j_i64(old_bytes.length().to_int64()),
        "patch_bytes": j_i64(patch_bytes.length().to_int64()),
        "target_bytes": j_i64(fixture.new_bytes.length().to_int64()),
        "written_bytes": j_i64(written_bytes),
        "buffer_ceiling_bytes": j_int(4096),
        "max_chunk_bytes": j_int(max_chunk_bytes),
        "target_sha256": j_str(fixture.target_sha256),
        "restored_sha256": j_null(),
        "counters": counters_json,
        "stages": j_arr(stages),
        "chunks": j_arr(chunks),
        "events": j_arr(events),
        "deep_info": j_null(),
        "error": j_obj({
          "error_type": j_str(err_type),
          "detail": j_str(err_detail),
          "bsdiff_error": bsdiff_json,
          "raw": j_str(@debug.to_string(err)),
        }),
      }).stringify()
    }
  }
}
