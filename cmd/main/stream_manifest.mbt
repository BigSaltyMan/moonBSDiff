///|
extern "C" fn stream_copy_begin() -> Int32 = "mbsd_stream_copy_begin"

///|
#borrow(data)
extern "C" fn stream_copy_write(data : Bytes) -> Int32 = "mbsd_stream_copy_write"

///|
extern "C" fn stream_copy_use(which : Int32) -> Int32 = "mbsd_stream_copy_use"

///|
fn stream_manifest(
  config : CliConfig,
  progress : StreamProgress,
) -> ManifestIdentity? raise {
  guard config.manifest is Some(path) else { return None }
  stream_require(
    io_check(
      path_bytes(config.files[0]),
      path_bytes(path),
      path_bytes(config.files[2]),
    ) !=
    0,
    "stream manifest/output precheck",
  )
  progress.checkpoint(2)
  let data = io_read(path_bytes(path), 16384)
  stream_require(io_failed() == 0, "read manifest (limit=16384 bytes)")
  let identity = parse_manifest(data)
  check_manifest_caps(identity, config.limits)
  Some(identity)
}

///|
fn verify_stream_copy(
  which : Int32,
  name : String,
  expected : ContentIdentity,
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
    digest_hex(hash.finish()) == expected.hash,
    "\{name} sha256 mismatch",
  )
  progress.checkpoint(2)
  stream_require(stream_copy_use(which) != 0, "\{name}: finish private copy")
}

///|
fn stream_output(
  data : Bytes,
  hash : @sha2.Hasher?,
  progress : StreamProgress,
) -> Unit raise {
  progress.checkpoint(20)
  stream_require(stream_write(data) != 0, "Applying: write temporary")
  if hash is Some(hasher) {
    hasher.write(data[:])
  }
  progress.written(data.length())
}
