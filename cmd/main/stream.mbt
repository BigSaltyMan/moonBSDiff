///|
#borrow(old, patch)
extern "C" fn stream_open(
  old : Bytes,
  patch : Bytes,
  oldcap : Int64,
  patchcap : Int64,
) -> Int32 = "mbsd_stream_open"

///|
extern "C" fn stream_size(which : Int32) -> Int64 = "mbsd_stream_size"

///|
extern "C" fn stream_read(
  which : Int32,
  offset : Int64,
  count : Int32,
) -> Bytes = "mbsd_stream_read"

///|
#borrow(data)
extern "C" fn stream_write(data : Bytes) -> Int32 = "mbsd_stream_write"

///|
#borrow(path, body, gate)
extern "C" fn stream_deliver(
  path : Bytes,
  call : FuncRef[(() -> Int32) -> Int32],
  body : () -> Int32,
  gate : () -> Int32,
) -> Int32 = "mbsd_stream_deliver"

///|
extern "C" fn stream_abort() -> Unit = "mbsd_stream_abort"

///|
suberror StreamError {
  StreamError(String)
}

///|
fn stream_require(ok : Bool, message : String) -> Unit raise StreamError {
  if !ok {
    raise StreamError(message)
  }
}

///|
priv enum CliStreamFault {
  Cancelled
  Failed(String)
}

///|
fn stream_checkpoint(
  progress : StreamProgress,
  point : Int32,
) -> Result[Unit, CliStreamFault] {
  try {
    progress.checkpoint(point)
    Ok(())
  } catch {
    StreamCancelled => Err(Cancelled)
  }
}

///|
fn stream_read_range(
  which : Int32,
  offset : Int64,
  count : Int32,
  label : String,
) -> Result[Bytes, CliStreamFault] {
  if count <= 0 {
    return Ok(b"")
  }
  if count <= 4096 {
    let data = stream_read(which, offset, count)
    if io_failed() != 0 {
      return Err(Failed(label))
    }
    return Ok(data)
  }
  let buf : Array[Byte] = []
  while buf.length() < count {
    let want = Int32::min(4096, count - buf.length())
    let data = stream_read(which, offset + buf.length().to_int64(), want)
    if io_failed() != 0 {
      return Err(Failed(label))
    }
    if data.length() == 0 {
      break
    }
    for b in data {
      buf.push(b)
    }
  }
  Ok(Bytes::from_array(buf))
}

///|
fn stream_bsdiff_message(err : @moonbsdiff.BsdiffError) -> String {
  match err {
    { kind: DecompressionFailed, field: Some("crc"), .. } =>
      "Checksum failure: " + @debug.to_string(err)
    { kind: InvalidField, stage: Control, value: Some(v), .. } if v < 0L =>
      "negative control instruction length: " + @debug.to_string(err)
    {
      kind: TruncatedData,
      stage: Control,
      field: Some("control_triple_bytes"),
      ..
    } => "TruncatedData: control triple truncated: " + @debug.to_string(err)
    _ => @debug.to_string(err)
  }
}

///|
fn stream_execute(
  info : @moonbsdiff.PatchInfo,
  limits : @moonbsdiff.Limits,
  progress : StreamProgress,
  expected : @manifest.ContentIdentity?,
  consume : (Bytes) -> Unit raise StreamError,
) -> Unit raise {
  let hash = expected.map(_ => @sha2.Hasher::new(kind=@sha2.Sha256))
  let old_size = stream_size(0)
  let patch_size = stream_size(1)
  let mut validating = false
  let outcome = @moonbsdiff.apply_stream(
    old_size,
    patch_size,
    limits,
    read_old_at=(offset, count) => {
      stream_read_range(0, offset, count, "Applying: old file read")
    },
    read_patch_at=(offset, count) => {
      stream_read_range(1, offset, count, "Applying: patch file read")
    },
    write_output=chunk => {
      match stream_checkpoint(progress, 20) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      consume(chunk) catch {
        StreamError(msg) => return Err(Failed(msg))
      }
      if hash is Some(hasher) {
        hasher.write(chunk[:])
      }
      try {
        progress.recovered(chunk.length())
        Ok(())
      } catch {
        StreamCancelled => Err(Cancelled)
      }
    },
    on_stage=stage => {
      match stage {
        @moonbsdiff.HeaderVerified(header) =>
          if header != info {
            Err(Failed("stream patch header changed during apply"))
          } else {
            Ok(())
          }
        @moonbsdiff.Restoring => Ok(())
        @moonbsdiff.Validating => {
          validating = true
          progress.phase("validating")
          stream_checkpoint(progress, 40)
        }
      }
    },
    checkpoint=() => {
      stream_checkpoint(progress, if validating { 40 } else { 20 })
    },
  )
  match outcome {
    Ok(_) => ()
    Err(Io(Cancelled)) => raise StreamCancelled
    Err(Io(Failed(msg))) => raise StreamError(msg)
    Err(Bsdiff(err)) => raise StreamError(stream_bsdiff_message(err))
  }
  if expected is Some(identity) && hash is Some(hasher) {
    progress.checkpoint(40)
    stream_require(
      progress.restored == identity.size,
      "restored new content size mismatch",
    )
    stream_require(
      @manifest_support.digest_hex(hasher.finish()) == identity.hash,
      "restored new content sha256 mismatch",
    )
  }
}

///|
fn stream_prepare_patch(
  limits : @moonbsdiff.Limits,
  expected : @manifest.ContentIdentity?,
  progress : StreamProgress,
) -> @moonbsdiff.PatchInfo raise {
  let header = stream_read(1, 0L, Int64::min(32L, stream_size(1)).to_int())
  stream_require(io_failed() == 0, "stream read header")
  let info = match
    @moonbsdiff.inspect_header_prefix(
      header,
      stream_size(1),
      limits.max_patch_bytes,
    ) {
    Ok(v) => v
    Err(e) => raise StreamError(@debug.to_string(e))
  }
  if expected is Some(new) {
    stream_require(
      info.new_bytes == new.size,
      "patch header/new size mismatch: header \{info.new_bytes}, manifest \{new.size}",
    )
  }
  for
    (field, cap) in [
      ("max_new_bytes", limits.max_new_bytes),
      ("max_output_bytes", limits.max_output_bytes),
    ] {
    stream_require(
      info.new_bytes <= cap,
      "Header ResourceLimitExceeded: \{field} value=\{info.new_bytes} limit=\{cap}",
    )
  }
  progress.total = Some(info.new_bytes)
  progress.phase("restoring")
  progress.checkpoint(10)
  info
}

///|
fn stream_restore_output(
  target : String,
  info : @moonbsdiff.PatchInfo,
  limits : @moonbsdiff.Limits,
  progress : StreamProgress,
  expected : @manifest.ContentIdentity?,
) -> Unit raise {
  let ok = stream_deliver(
    path_bytes(target),
    fn(f) { f() },
    fn() {
      progress.attempt(() => {
        stream_execute(info, limits, progress, expected, data => {
          stream_require(stream_write(data) != 0, "Applying: write temporary")
        })
      })
    },
    fn() {
      progress.attempt(() => {
        progress.phase("delivering")
        progress.checkpoint(50)
        let admitted = interrupt_commit(progress.session)
        if admitted == 0 {
          progress.cancelled = true
          raise StreamCancelled
        }
        stream_require(admitted == 1, "Interrupt commit admission failed")
        progress.committing = true
      })
    },
  )
  if ok == 0 {
    if progress.cancelled {
      raise StreamCancelled
    }
    // A signal noticed while a pull raised is confirmed here, never mistaken
    // for a successful EOF or reported as a cancellation after commit began.
    progress.checkpoint(0)
    raise StreamError(
      if progress.detail == "" {
        "stream output delivery"
      } else {
        progress.detail
      },
    )
  }
}

///|
fn stream_run(config : CliConfig, progress : StreamProgress) -> Unit raise {
  let limits = config.limits
  let output = if config.operation == "patch" {
    Some(config.files[2])
  } else {
    None
  }
  if output is Some(target) {
    let inputs = [config.files[0], config.files[1]]
    if config.manifest is Some(m) {
      inputs.push(m)
    }
    for pk in config.public_keys {
      inputs.push(pk)
    }
    if config.signature is Some(sig) {
      inputs.push(sig)
    }
    stream_require(
      check_output_against(inputs, target),
      "stream output precheck",
    )
  }
  let identity = stream_manifest(config, progress)
  progress.checkpoint(2)
  stream_require(
    stream_open(
      path_bytes(config.files[0]),
      path_bytes(config.files[1]),
      limits.max_old_bytes,
      limits.max_patch_bytes,
    ) !=
    0,
    "stream open",
  )
  progress.checkpoint(2)
  if identity is Some(manifest) {
    progress.phase("preparing")
    verify_stream_copy(0, "old input", manifest.old, progress)
    verify_stream_copy(1, "patch input", manifest.patch, progress)
    progress.checkpoint(23)
  }
  let expected = identity.map(m => m.new)
  let info = stream_prepare_patch(limits, expected, progress)
  guard output is Some(target) else {
    stream_execute(info, limits, progress, expected, _ => ())
    return
  }
  stream_restore_output(target, info, limits, progress, expected)
}

///|
fn stream_command(config : CliConfig) -> Unit {
  let outcome = stream_operation(config)
  if outcome != 0 {
    @env.exit(outcome)
    return
  }
  if config.operation == "verify-chain" {
    if !config.public_keys.is_empty() {
      println(
        "Chain verification succeeded: signatures and all steps match the supplied manifests.",
      )
    } else {
      println(
        "Chain verification succeeded: all steps match the supplied manifests.",
      )
    }
  }
}
