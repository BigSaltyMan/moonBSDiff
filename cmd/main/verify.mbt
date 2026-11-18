///|
// Schema/input failures are runtime failures, never partially successful output.
fn[T] manifest_failure(message : String) -> T {
  failure(message)
  abort("unreachable after process exit")
}

///|
struct ContentIdentity {
  size : Int64
  hash : String
}

///|
struct ManifestIdentity {
  old : ContentIdentity
  new : ContentIdentity
  patch : ContentIdentity
}

///|
fn manifest_object(
  value : @json.Json,
  keys : Array[String],
  context : String,
) -> Map[String, @json.Json] raise StreamError {
  let fields = match value {
    @json.Object(fields) => fields
    _ => raise StreamError("manifest schema: " + context + " must be an object")
  }
  for key in keys {
    if fields.get(key) is None {
      raise StreamError("manifest schema: missing " + context + "." + key)
    }
  }
  if fields.length() != keys.length() {
    raise StreamError("manifest schema: unknown fields in " + context)
  }
  fields
}

///|
fn manifest_field(
  fields : Map[String, @json.Json],
  key : String,
) -> @json.Json raise StreamError {
  match fields.get(key) {
    Some(value) => value
    None => raise StreamError("manifest schema: missing " + key)
  }
}

///|
fn manifest_string(
  value : @json.Json,
  context : String,
) -> String raise StreamError {
  match value {
    @json.String(value) => value
    _ => raise StreamError("manifest schema: " + context + " must be a string")
  }
}

///|
fn content_identity(
  value : @json.Json,
  context : String,
) -> ContentIdentity raise StreamError {
  let fields = manifest_object(value, ["size_bytes", "sha256"], context)
  let text = manifest_string(
    manifest_field(fields, "size_bytes"),
    context + ".size_bytes",
  )
  let raw = @utf8.encode(text[:])
  if raw.length() == 0 {
    raise StreamError("manifest size: " + context + " is empty")
  }
  let mut size = 0L
  for byte in raw {
    let digit = byte.to_int() - 48
    if digit < 0 || digit > 9 {
      raise StreamError(
        "manifest size: " +
        context +
        " requires nonnegative ASCII decimal digits",
      )
    }
    if size > (9223372036854775807L - digit.to_int64()) / 10L {
      raise StreamError("manifest size: " + context + " overflows Int64")
    }
    size = size * 10L + digit.to_int64()
  }
  let hash = manifest_string(
    manifest_field(fields, "sha256"),
    context + ".sha256",
  )
  let encoded = @utf8.encode(hash[:])
  if encoded.length() != 64 {
    raise StreamError(
      "manifest sha256: " + context + " requires 64 lowercase hex digits",
    )
  }
  for byte in encoded {
    let code = byte.to_int()
    if !((code >= 48 && code <= 57) || (code >= 97 && code <= 102)) {
      raise StreamError(
        "manifest sha256: " + context + " requires lowercase hex digits",
      )
    }
  }
  { size, hash, }
}

///|
fn parse_manifest(data : Bytes) -> ManifestIdentity raise StreamError {
  let text = @utf8.decode(data[:], ignore_bom=false) catch {
    _ => raise StreamError("manifest encoding: expected valid UTF-8")
  }
  let json = @json.parse(
    text[:],
    max_nesting_depth=8,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    e => raise StreamError("manifest JSON: " + @debug.to_string(e))
  }
  let fields = manifest_object(
    json,
    ["schema_version", "patch_format", "producer", "old", "new", "patch"],
    "root",
  )
  if !(manifest_field(fields, "schema_version")
    is @json.Number(_, repr=Some("1"))) {
    raise StreamError("manifest schema_version: expected integer 1")
  }
  if manifest_string(manifest_field(fields, "patch_format"), "patch_format") !=
    "BSDIFF40" {
    raise StreamError("manifest patch_format: only BSDIFF40 is supported")
  }
  let producer = manifest_object(
    manifest_field(fields, "producer"),
    ["name", "version"],
    "producer",
  )
  manifest_string(manifest_field(producer, "name"), "producer.name") |> ignore
  manifest_string(manifest_field(producer, "version"), "producer.version")
  |> ignore
  {
    old: content_identity(manifest_field(fields, "old"), "old"),
    new: content_identity(manifest_field(fields, "new"), "new"),
    patch: content_identity(manifest_field(fields, "patch"), "patch"),
  }
}

///|
fn manifest_cap(
  name : String,
  size : Int64,
  limit : Int64,
) -> Unit raise StreamError {
  if size > limit {
    raise StreamError(
      "manifest limits: " +
      name +
      " declared size \{size} exceeds limit \{limit}",
    )
  }
}

///|
fn check_manifest_caps(
  identity : ManifestIdentity,
  limits : @moonbsdiff.Limits,
) -> Unit raise StreamError {
  manifest_cap("old/max_old_bytes", identity.old.size, limits.max_old_bytes)
  manifest_cap(
    "patch/max_patch_bytes",
    identity.patch.size,
    limits.max_patch_bytes,
  )
  manifest_cap("new/max_new_bytes", identity.new.size, limits.max_new_bytes)
  manifest_cap(
    "new/max_output_bytes",
    identity.new.size,
    limits.max_output_bytes,
  )
}

///|
fn check_content(
  name : String,
  data : Bytes,
  expected : ContentIdentity,
) -> Unit {
  if data.length().to_int64() != expected.size {
    failure(
      name + " size mismatch: expected \{expected.size}, got \{data.length()}",
    )
  }
  if sha256_hex(data) != expected.hash {
    failure(name + " sha256 mismatch")
  }
}

///|
fn verified_restore(config : CliConfig) -> Bytes {
  let manifest_path = match config.manifest {
    Some(path) => path
    None => return manifest_failure("verify requires --manifest")
  }
  let limits = config.limits
  let data = read_input(
    "read manifest (limit=16384 bytes)", manifest_path, 16384L,
  )
  let identity = try {
    let identity = parse_manifest(data)
    check_manifest_caps(identity, limits)
    identity
  } catch {
    StreamError(message) => return manifest_failure(message)
  }
  let old = read_input(
    "verified read old (max_old_bytes=\{limits.max_old_bytes})",
    config.files[0],
    limits.max_old_bytes,
  )
  let patch = read_input(
    "verified read patch (max_patch_bytes=\{limits.max_patch_bytes})",
    config.files[1],
    limits.max_patch_bytes,
  )
  check_content("old input", old, identity.old)
  check_content("patch input", patch, identity.patch)
  let info = match @moonbsdiff.inspect_header(patch, limits.max_patch_bytes) {
    Ok(value) => value
    Err(e) => return manifest_failure("patch header: " + @debug.to_string(e))
  }
  if info.new_bytes != identity.new.size {
    return manifest_failure(
      "patch header/new size mismatch: header \{info.new_bytes}, manifest \{identity.new.size}",
    )
  }
  // These exact immutable buffers were hashed above; never reopen their paths.
  let restored = match @moonbsdiff.apply(old, patch, limits) {
    Ok(value) => value
    Err(e) =>
      return manifest_failure("restoration apply: " + @debug.to_string(e))
  }
  check_content("restored new content", restored, identity.new)
  restored
}

///|
fn verify_command(config : CliConfig) -> Unit {
  if config.stream {
    let outcome = stream_operation(config)
    if outcome != 0 {
      @env.exit(outcome)
      return
    }
  } else {
    verified_restore(config) |> ignore
  }
  println(
    "Verification succeeded: manifest, inputs and restored content match (not publisher authentication).",
  )
}
