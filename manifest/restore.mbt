///|
#derive(Eq, Debug)
pub(all) enum ContentObject {
  Old
  Patch
  PatchTarget
  Restored
}

///|
#derive(Eq, Debug)
pub(all) enum IdentityDifference {
  Size(expected~ : Int64, actual~ : Int64)
  Sha256
}

///|
/// Errors from reading a schema 1 manifest or restoring its bound content.
#derive(Eq, Debug)
pub(all) enum ManifestError {
  InvalidLimits(@moonbsdiff.BsdiffError)
  InvalidEncoding
  InvalidJson(field~ : String?, detail~ : String)
  InvalidSchema(field~ : String, detail~ : String)
  LimitExceeded(field~ : String, value~ : Int64, limit~ : Int64)
  IdentityMismatch(object~ : ContentObject, difference~ : IdentityDifference)
  HeaderError(@moonbsdiff.BsdiffError)
  ApplyError(@moonbsdiff.BsdiffError)
}

///|
pub extend ContentObject with Eq::{equal, not_equal}

///|
pub extend ContentObject with @debug.Debug::{to_repr}

///|
pub extend IdentityDifference with Eq::{equal, not_equal}

///|
pub extend IdentityDifference with @debug.Debug::{to_repr}

///|
pub extend ManifestError with Eq::{equal, not_equal}

///|
pub extend ManifestError with @debug.Debug::{to_repr}

///|
/// Identity by byte count and SHA-256. Preflight checks declared identities.
#derive(Eq)
pub struct ContentIdentity {
  size : Int64
  hash : String
}

///|
pub extend ContentIdentity with Eq::{equal, not_equal}

///|
/// Compute size and SHA-256 once for an actual buffer.
pub fn ContentIdentity::of_bytes(data : Bytes) -> ContentIdentity {
  { size: data.length().to_int64(), hash: @manifest_support.sha256_hex(data), }
}

///|
/// Preflight result. Restore uses the same limits that were checked.
pub struct PreparedManifest {
  old : ContentIdentity
  new : ContentIdentity
  patch : ContentIdentity
  priv limits : @moonbsdiff.Limits
}

///|
fn parse_bounded_manifest(
  data : Bytes,
  limits : @moonbsdiff.Limits,
) -> PreparedManifest raise ManifestFault {
  match limits.validate() {
    Ok(_) => ()
    Err(error) => raise Rejected(InvalidLimits(error))
  }
  let size = data.length().to_int64()
  let cap = @manifest_support.MAX_MANIFEST_BYTES.to_int64()
  check_declared_size("max_manifest_bytes", size, cap)
  parse_manifest(data, limits)
}

///|
fn check_declared_size(
  field : String,
  value : Int64,
  limit : Int64,
) -> Unit raise ManifestFault {
  if value > limit {
    raise Rejected(LimitExceeded(field~, value~, limit~))
  }
}

///|
fn check_target_size(
  target : ContentIdentity,
  limits : @moonbsdiff.Limits,
) -> Unit raise ManifestFault {
  check_declared_size("max_new_bytes", target.size, limits.max_new_bytes)
  check_declared_size("max_output_bytes", target.size, limits.max_output_bytes)
}

///|
/// Check the manifest and declared sizes before obtaining the input buffers.
pub fn prepare(
  data : Bytes,
  limits : @moonbsdiff.Limits,
) -> Result[PreparedManifest, ManifestError] {
  try {
    let prepared = parse_bounded_manifest(data, limits)
    check_declared_size(
      "max_old_bytes",
      prepared.old.size,
      limits.max_old_bytes,
    )
    check_declared_size(
      "max_patch_bytes",
      prepared.patch.size,
      limits.max_patch_bytes,
    )
    check_target_size(prepared.new, limits)
    Ok(prepared)
  } catch {
    Rejected(error) => Err(error)
  }
}

///|
/// Validate the whole schema and return the new identity for a full download.
/// Only the new and output byte limits apply to the declared sizes.
pub fn prepare_target(
  data : Bytes,
  limits : @moonbsdiff.Limits,
) -> Result[ContentIdentity, ManifestError] {
  try {
    let prepared = parse_bounded_manifest(data, limits)
    check_target_size(prepared.new, limits)
    Ok(prepared.new)
  } catch {
    Rejected(error) => Err(error)
  }
}

///|
fn check_content(
  object : ContentObject,
  data : Bytes,
  expected : ContentIdentity,
) -> Unit raise ManifestFault {
  let actual = data.length().to_int64()
  if actual != expected.size {
    raise Rejected(
      IdentityMismatch(
        object~,
        difference=Size(expected=expected.size, actual~),
      ),
    )
  }
  if @manifest_support.sha256_hex(data) != expected.hash {
    raise Rejected(IdentityMismatch(object~, difference=Sha256))
  }
}

///|
/// Check the actual input identities and the restored bytes before returning.
pub fn PreparedManifest::restore(
  self : PreparedManifest,
  old : Bytes,
  patch : Bytes,
) -> Result[Bytes, ManifestError] {
  try {
    check_content(Old, old, self.old)
    check_content(Patch, patch, self.patch)
    let header = match
      @moonbsdiff.inspect_header(patch, self.limits.max_patch_bytes) {
      Ok(value) => value
      Err(error) => raise Rejected(HeaderError(error))
    }
    if header.new_bytes != self.new.size {
      raise Rejected(
        IdentityMismatch(
          object=PatchTarget,
          difference=Size(expected=self.new.size, actual=header.new_bytes),
        ),
      )
    }
    // Apply receives the same immutable buffers whose identities were checked.
    let restored = match @moonbsdiff.apply(old, patch, self.limits) {
      Ok(value) => value
      Err(error) => raise Rejected(ApplyError(error))
    }
    check_content(Restored, restored, self.new)
    Ok(restored)
  } catch {
    Rejected(error) => Err(error)
  }
}
