///|
#derive(Eq, Hash, Compare)
priv struct ManifestIdentity {
  size : Int64
  hash : String
}

///|
fn manifest_identity(identity : @manifest.ContentIdentity) -> ManifestIdentity {
  { size: identity.size, hash: identity.hash, }
}

///|
fn manifest_identity_json(identity : ManifestIdentity) -> @json.Json {
  @json.Json::object({
    "size_bytes": @json.Json::string("\{identity.size}"),
    "sha256": @json.Json::string(identity.hash),
  })
}

///|
fn installed_identity(
  operation : String,
  path : String,
  limits : @moonbsdiff.Limits,
) -> ManifestIdentity {
  let old = read_input(
    "\{operation} read old (max_old_bytes=\{limits.max_old_bytes} bytes)",
    path,
    limits.max_old_bytes,
  )
  { size: old.length().to_int64(), hash: @manifest_support.sha256_hex(old), }
}

///|
fn read_prepared_manifest(
  operation : String,
  path : String,
  limits : @moonbsdiff.Limits,
) -> @manifest.PreparedManifest {
  let cap = @manifest_support.MAX_MANIFEST_BYTES.to_int64()
  let data = read_input("\{operation} read (limit=\{cap} bytes)", path, cap)
  match @manifest.prepare(data, limits) {
    Ok(value) => value
    Err(error) =>
      manifest_failure("\{operation} '\{path}': " + manifest_diagnostic(error))
  }
}

///|
fn manifest_create_command(config : CliConfig) -> Unit {
  let old_path = config.files[0]
  let new_path = config.files[1]
  let patch_path = config.files[2]
  let output_path = config.files[3]
  let output = path_bytes(output_path)
  // The preflight rejects any existing output entry, including input aliases.
  if io_check(path_bytes(old_path), path_bytes(new_path), output) == 0 {
    failure(
      "manifest create output '\{output_path}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  let limits = config.limits
  let old = read_input(
    "manifest create read old (max_old_bytes=\{limits.max_old_bytes} bytes)",
    old_path,
    limits.max_old_bytes,
  )
  let new = read_input(
    "manifest create read expected new (max_new_bytes=\{limits.max_new_bytes}, max_output_bytes=\{limits.max_output_bytes} bytes)",
    new_path,
    Int64::min(limits.max_new_bytes, limits.max_output_bytes),
  )
  let patch = read_input(
    "manifest create read patch (max_patch_bytes=\{limits.max_patch_bytes} bytes)",
    patch_path,
    limits.max_patch_bytes,
  )
  let restored = match @moonbsdiff.apply(old, patch, limits) {
    Ok(bytes) => bytes
    Err(error) => {
      failure(
        "manifest create apply '\{patch_path}': " + @debug.to_string(error),
      )
      return
    }
  }
  if restored != new {
    failure(
      "manifest create: restored content differs from expected new file '\{new_path}'",
    )
    return
  }
  if io_deliver(output, @manifest_support.make_manifest(old, new, patch)) == 0 {
    failure(
      "manifest create write/deliver '\{output_path}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
  }
}
