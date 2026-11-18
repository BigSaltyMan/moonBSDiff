///|
fn manifest_entry(data : Bytes) -> @json.Json {
  @json.Json::object({
    "size_bytes": @json.Json::string("\{data.length()}"),
    "sha256": @json.Json::string(@manifest_support.sha256_hex(data)),
  })
}

///|
fn make_manifest(old : Bytes, new : Bytes, patch : Bytes) -> Bytes {
  let document = @json.Json::object({
    "schema_version": @json.Json::number(1.0),
    "patch_format": @json.Json::string("BSDIFF40"),
    "producer": @json.Json::object({
      "name": @json.Json::string("moonbsdiff"),
      "version": @json.Json::string(cli_version),
    }),
    "old": manifest_entry(old),
    "new": manifest_entry(new),
    "patch": manifest_entry(patch),
  })
  @utf8.encode((document.stringify() + "\n")[:])
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
  if io_deliver(output, make_manifest(old, new, patch)) == 0 {
    failure(
      "manifest create write/deliver '\{output_path}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
  }
}
