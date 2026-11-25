///|
extern "C" fn stream_copy_begin() -> Int32 = "mbsd_stream_copy_begin"

///|
#borrow(data)
extern "C" fn stream_copy_write(data : Bytes) -> Int32 = "mbsd_stream_copy_write"

///|
extern "C" fn stream_copy_use(which : Int32) -> Int32 = "mbsd_stream_copy_use"

///|
fn stream_read_manifest_data(
  path : String,
  progress : StreamProgress,
) -> Bytes raise {
  progress.checkpoint(2)
  let data = io_read(path_bytes(path), @manifest_support.MAX_MANIFEST_BYTES)
  stream_require(
    io_failed() == 0,
    "read manifest (limit=16384 bytes) '\{path}'",
  )
  progress.checkpoint(2)
  data
}

///|
fn stream_prepare_manifest(
  data : Bytes,
  path : String,
  limits : @moonbsdiff.Limits,
) -> @manifest.PreparedManifest raise StreamError {
  match @manifest.prepare(data, limits) {
    Ok(identity) => identity
    Err(error) =>
      raise StreamError("manifest '\{path}': " + manifest_diagnostic(error))
  }
}

///|
fn stream_manifest(
  config : CliConfig,
  progress : StreamProgress,
) -> @manifest.PreparedManifest? raise {
  guard config.manifest is Some(path) else { return None }
  let data = stream_read_manifest_data(path, progress)
  progress.checkpoint(2)
  match
    prepare_optional_signed_manifest(
      config.operation,
      path,
      data,
      config.limits,
      config.public_keys,
      config.signature,
    ) {
    Ok(prepared) => {
      progress.checkpoint(2)
      Some(prepared)
    }
    Err(msg) => raise StreamError(msg)
  }
}

///|
fn verify_stream_copy(
  which : Int32,
  name : String,
  expected : @manifest.ContentIdentity,
  progress : StreamProgress,
) -> Unit raise {
  let actual = stream_size(which)
  stream_require(
    actual == expected.size,
    "\{name} size mismatch: expected \{expected.size}, got \{actual}",
  )
  progress.checkpoint(2)
  stream_require(stream_copy_begin() != 0, "\{name}: create private copy")
  let hash = @sha2.Hasher::new(kind=@sha2.Sha256)
  let mut offset = 0L
  // Open already checked the length against Limits. Each exact read/write
  // consumes only remaining declared bytes. The handle transfer checks EOF.
  while offset < actual {
    progress.checkpoint(2)
    let count = Int64::min(4096L, actual - offset).to_int()
    let data = stream_read(which, offset, count)
    stream_require(
      data.length() == count && io_failed() == 0,
      "\{name}: read for private copy",
    )
    progress.checkpoint(2)
    stream_require(stream_copy_write(data) != 0, "\{name}: write private copy")
    hash.write(data[:])
    offset += count.to_int64()
    progress.checkpoint(22)
  }
  stream_require(
    @manifest_support.digest_hex(hash.finish()) == expected.hash,
    "\{name} sha256 mismatch",
  )
  progress.checkpoint(2)
  stream_require(stream_copy_use(which) != 0, "\{name}: finish private copy")
}
