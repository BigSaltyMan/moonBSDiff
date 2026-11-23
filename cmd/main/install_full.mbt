///|
#borrow(path)
extern "C" fn stream_open_full(path : Bytes, cap : Int64) -> Int32 = "mbsd_stream_open_full"

///|
extern "C" fn stream_expect_eof(which : Int32) -> Int32 = "mbsd_stream_expect_eof"

///|
fn copy_full_target(
  target : @manifest.ContentIdentity,
) -> Unit raise StreamError {
  let hash = @sha2.Hasher::new(kind=@sha2.Sha256)
  let mut written = 0L
  while written < target.size {
    let count = Int64::min(4096L, target.size - written).to_int()
    let chunk = stream_read(0, written, count)
    stream_require(
      chunk.length() == count && io_failed() == 0,
      "read downloaded file",
    )
    stream_require(stream_write(chunk) != 0, "write temporary output")
    hash.write(chunk[:])
    written += chunk.length().to_int64()
  }
  stream_require(stream_expect_eof(0) != 0, "verify downloaded file EOF")
  stream_require(
    @manifest_support.digest_hex(hash.finish()) == target.hash,
    "downloaded file sha256 mismatch",
  )
}

///|
fn install_full_command(config : CliConfig) -> Unit {
  let manifest = config.target_manifest.unwrap()
  let source = path_bytes(config.files[0])
  let output = config.files[1]
  let destination = path_bytes(output)
  let data = read_input(
    "install-full read manifest (limit=16384 bytes)",
    manifest,
    @manifest_support.MAX_MANIFEST_BYTES.to_int64(),
  )
  verify_optional_manifest_signature(
    "install-full",
    data,
    config.public_key,
    config.signature,
  )
  |> ignore
  let target = match @manifest.prepare_target(data, config.limits) {
    Ok(target) => target
    Err(error) =>
      return manifest_failure(
        "install-full '\{manifest}': " + manifest_diagnostic(error),
      )
  }
  let inputs = [config.files[0], manifest]
  if config.public_key is Some(pk) {
    inputs.push(pk)
  }
  if config.signature is Some(sig) {
    inputs.push(sig)
  }
  if !check_output_against(inputs, output) {
    failure(
      "install-full output '\{output}': " + @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  let cap = Int64::min(
    config.limits.max_new_bytes,
    config.limits.max_output_bytes,
  )
  if stream_open_full(source, cap) == 0 {
    let error = @utf8.decode_lossy(io_error()[:])
    stream_abort()
    failure("install-full '\{config.files[0]}': open downloaded file; " + error)
    return
  }
  let size = stream_size(0)
  if size != target.size {
    stream_abort()
    failure(
      "install-full '\{output}': downloaded file size mismatch: expected \{target.size}, got \{size}",
    )
    return
  }
  let mut reason = ""
  let ok = stream_deliver(
    destination,
    fn(f) { f() },
    fn() {
      try {
        copy_full_target(target)
        1
      } catch {
        StreamError(message) => {
          reason = message + "; "
          0
        }
      }
    },
    () => 1,
  )
  if ok == 0 || stream_published() == 0 {
    let detail = if io_failed() != 0 {
      @utf8.decode_lossy(io_error()[:])
    } else {
      "delivery returned without publication"
    }
    let state = if stream_published() != 0 &&
      !detail.has_prefix("output already delivered;") {
      "output already delivered; "
    } else {
      ""
    }
    failure("install-full '\{output}': " + state + reason + detail)
  }
}
