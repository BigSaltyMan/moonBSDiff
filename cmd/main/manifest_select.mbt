///|
fn selection_identity(identity : @manifest.ContentIdentity) -> @json.Json {
  @json.Json::object({
    "size_bytes": @json.Json::string("\{identity.size}"),
    "sha256": @json.Json::string(identity.hash),
  })
}

///|
fn manifest_select_command(config : CliConfig) -> Unit {
  let limits = config.limits
  let old_path = config.files[0]
  let (old_size, old_hash) = {
    let old = read_input(
      "manifest select read old (max_old_bytes=\{limits.max_old_bytes} bytes)",
      old_path,
      limits.max_old_bytes,
    )
    (old.length().to_int64(), @manifest_support.sha256_hex(old))
  }
  let manifest_cap = @manifest_support.MAX_MANIFEST_BYTES.to_int64()
  let mut target : @manifest.ContentIdentity? = None
  let mut best : (String, @manifest.ContentIdentity)? = None
  for i in 1..<config.files.length() {
    let path = config.files[i]
    let data = read_input(
      "manifest select read (limit=\{manifest_cap} bytes)",
      path,
      manifest_cap,
    )
    let candidate = match @manifest.prepare(data, limits) {
      Ok(value) => value
      Err(error) => {
        failure("manifest select '\{path}': " + manifest_diagnostic(error))
        return
      }
    }
    if target is Some(expected) {
      if candidate.new.size != expected.size ||
        candidate.new.hash != expected.hash {
        let field = if candidate.new.size != expected.size {
          "new.size_bytes"
        } else {
          "new.sha256"
        }
        failure(
          "manifest select '\{path}': target mismatch with '\{config.files[1]}' (\{field})",
        )
        return
      }
    } else {
      target = Some(candidate.new)
    }
    if candidate.old.size == old_size && candidate.old.hash == old_hash {
      // Strictly smaller wins. Equal sizes keep the earlier command-line item.
      if best is Some((_, current)) && current.size <= candidate.patch.size {
        continue
      }
      best = Some((path, candidate.patch))
    }
  }
  guard best is Some((path, patch)) && target is Some(new) else {
    failure(
      "manifest select: no manifest matches size and SHA-256 of old file '\{old_path}'",
    )
    return
  }
  let selected = @json.Json::object({
    "schema_version": @json.Json::number(1.0),
    "manifest_path": @json.Json::string(path),
    "patch": selection_identity(patch),
    "new": selection_identity(new),
  })
  println(selected.stringify())
}
