///|
fn manifest_diagnostic(error : @manifest.ManifestError) -> String {
  match error {
    InvalidLimits(reason) => @debug.to_string(reason)
    InvalidEncoding => "manifest encoding: expected valid UTF-8"
    InvalidJson(detail~, ..) => "manifest JSON: " + detail
    InvalidSchema(detail~, ..) => detail
    LimitExceeded(field~, value~, limit~) => {
      let object = match field {
        "max_old_bytes" => "old"
        "max_patch_bytes" => "patch"
        "max_manifest_bytes" => "manifest"
        _ => "new"
      }
      "manifest limits: \{object}/\{field} declared size \{value} exceeds limit \{limit}"
    }
    IdentityMismatch(object=PatchTarget, difference=Size(expected~, actual~)) =>
      "patch header/new size mismatch: header \{actual}, manifest \{expected}"
    IdentityMismatch(object~, difference~) => {
      let name = match object {
        Old => "old input"
        Patch => "patch input"
        PatchTarget => "patch header/new"
        Restored => "restored new content"
      }
      match difference {
        Size(expected~, actual~) =>
          "\{name} size mismatch: expected \{expected}, got \{actual}"
        Sha256 => "\{name} sha256 mismatch"
      }
    }
    HeaderError(reason) => "patch header: " + @debug.to_string(reason)
    ApplyError(reason) => "restoration apply: " + @debug.to_string(reason)
  }
}

///|
// Schema/input failures are runtime failures, never partially successful output.
fn[T] manifest_failure(message : String) -> T {
  failure(message)
  abort("unreachable after process exit")
}

///|
fn verified_restore(config : CliConfig) -> Bytes {
  let manifest_path = match config.manifest {
    Some(path) => path
    None => return manifest_failure("verify requires --manifest")
  }
  let limits = config.limits
  let data = read_input(
    "read manifest (limit=16384 bytes)",
    manifest_path,
    @manifest_support.MAX_MANIFEST_BYTES.to_int64(),
  )
  let prepared = match @manifest.prepare(data, limits) {
    Ok(value) => value
    Err(error) => return manifest_failure(manifest_diagnostic(error))
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
  match prepared.restore(old, patch) {
    Ok(value) => value
    Err(error) => manifest_failure(manifest_diagnostic(error))
  }
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
