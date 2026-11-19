///|
fn manifest_select_command(config : CliConfig) -> Unit {
  let limits = config.limits
  let old_path = config.files[0]
  let old = installed_identity("manifest select", old_path, limits)
  let mut target : @manifest.ContentIdentity? = None
  let mut best : (String, @manifest.ContentIdentity)? = None
  for i in 1..<config.files.length() {
    let path = config.files[i]
    let candidate = read_prepared_manifest("manifest select", path, limits)
    let new = candidate.new
    if target is Some(expected) {
      if new != expected {
        let field = if new.size != expected.size {
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
      target = Some(new)
    }
    if candidate.old == old {
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
    "patch": manifest_identity_json(patch),
    "new": manifest_identity_json(new),
  })
  println(selected.stringify())
}
