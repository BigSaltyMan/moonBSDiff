///|
pub let max_catalog_file_bytes : Int32 = 262144

///|
let catalog_signature_domain : Bytes = b"moonbsdiff-catalog-ed25519-v1\x00"

///|
let catalog_max_releases : Int32 = 4096

///|
let catalog_max_patches : Int32 = 16384

///|
let catalog_max_channel_bytes : Int32 = 64

///|
let catalog_max_label_bytes : Int32 = 64

///|
let catalog_max_uri_bytes : Int32 = 512

///|
let catalog_min_patch_bytes : Int64 = 32L

///|
/// Pinned set of trusted Ed25519 public keys supporting zero-downtime key rotation.
#derive(Eq, Debug)
pub struct TrustStore {
  priv keys : ReadOnlyArray[PublicKey]
  priv key_ids : ReadOnlyArray[String]
  priv by_id : Map[String, PublicKey]
}

///|
pub extend TrustStore with Eq::{equal, not_equal}

///|
pub extend TrustStore with @debug.Debug::{to_repr}

///|
/// Construct a TrustStore from one or more pinned Ed25519 public keys.
/// Identical keys are deduplicated preserving first-seen order.
/// Conflicting keys sharing the same key_id are rejected.
pub fn TrustStore::from_keys(
  keys : Array[PublicKey],
) -> Result[TrustStore, SignatureError] {
  if keys.is_empty() {
    return Err(
      InvalidSchema(
        field="keys",
        detail="trust store must contain at least one public key",
      ),
    )
  }
  let unique_keys : Array[PublicKey] = []
  let unique_ids : Array[String] = []
  let by_id : Map[String, PublicKey] = Map([])
  for key in keys {
    if !validate_canonical_ed25519_point(key.raw[:]) {
      return Err(
        InvalidPublicKey(
          detail="invalid, non-canonical, off-curve, or small-order Ed25519 public key",
        ),
      )
    }
    match by_id.get(key.key_id) {
      Some(existing) =>
        if existing.raw != key.raw {
          return Err(
            InvalidPublicKey(
              detail="conflicting public keys share key_id " + key.key_id,
            ),
          )
        }
      None => {
        by_id[key.key_id] = key
        unique_keys.push(key)
        unique_ids.push(key.key_id)
      }
    }
  }
  Ok({
    keys: ReadOnlyArray::makei(unique_keys.length(), i => unique_keys[i]),
    key_ids: ReadOnlyArray::makei(unique_ids.length(), i => unique_ids[i]),
    by_id,
  })
}

///|
pub fn TrustStore::len(self : TrustStore) -> Int32 {
  self.keys.length()
}

///|
pub fn TrustStore::key_ids(self : TrustStore) -> ReadOnlyArray[String] {
  self.key_ids
}

///|
pub fn TrustStore::find(self : TrustStore, key_id : String) -> PublicKey? {
  self.by_id.get(key_id)
}

///|
fn catalog_join_key_ids(ids : ReadOnlyArray[String]) -> String {
  let out = StringBuilder()
  for i = 0; i < ids.length(); i = i + 1 {
    if i > 0 {
      out.write_char(',')
    }
    out.write_string(ids[i])
  }
  out.to_string()
}

///|
/// Verify a detached manifest signature against any trusted key in this store,
/// returning the verifying PublicKey on success.
pub fn TrustStore::verify_manifest_signature(
  self : TrustStore,
  manifest_bytes : Bytes,
  sig : ManifestSignature,
) -> Result[PublicKey, SignatureError] {
  match check_manifest_size_limit(manifest_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let public_key = match self.by_id.get(sig.key_id) {
    Some(pk) => pk
    None =>
      return Err(
        KeyIdMismatch(
          expected=catalog_join_key_ids(self.key_ids),
          actual=sig.key_id,
        ),
      )
  }
  match verify_manifest_signature(manifest_bytes, sig, public_key) {
    Ok(_) => Ok(public_key)
    Err(err) => Err(err)
  }
}

///|
/// Errors from batch-verifying and preparing signed candidate manifests.
#derive(Eq, Debug)
pub(all) enum SignedCandidateError {
  InvalidLimits(@moonbsdiff.BsdiffError)
  Signature(index~ : Int32, error~ : SignatureError)
  Manifest(index~ : Int32, error~ : ManifestError)
}

///|
pub extend SignedCandidateError with Eq::{equal, not_equal}

///|
pub extend SignedCandidateError with @debug.Debug::{to_repr}

///|
/// Validate `limits`, then verify EVERY candidate manifest's detached signature
/// against the TrustStore BEFORE preparing any manifest, failing closed on the
/// first invalid signature.
pub fn verify_signed_candidates(
  store : TrustStore,
  candidates : Array[(Bytes, ManifestSignature)],
  limits : @moonbsdiff.Limits,
) -> Result[Array[PreparedManifest], SignedCandidateError] {
  match limits.validate() {
    Ok(_) => ()
    Err(err) => return Err(InvalidLimits(err))
  }
  for i = 0; i < candidates.length(); i = i + 1 {
    let (manifest_bytes, sig) = candidates[i]
    match store.verify_manifest_signature(manifest_bytes, sig) {
      Ok(_) => ()
      Err(error) => return Err(Signature(index=i, error~))
    }
  }
  let prepared : Array[PreparedManifest] = []
  for i = 0; i < candidates.length(); i = i + 1 {
    let (manifest_bytes, _) = candidates[i]
    match prepare(manifest_bytes, limits) {
      Ok(item) => prepared.push(item)
      Err(error) => return Err(Manifest(index=i, error~))
    }
  }
  Ok(prepared)
}

///|
/// Errors from parsing, constructing, signing, verifying, or planning updates
/// against a signed release catalog.
#derive(Eq, Debug)
pub(all) enum CatalogError {
  InvalidLimits(@moonbsdiff.BsdiffError)
  InvalidEncoding
  InvalidJson(field~ : String?, detail~ : String)
  InvalidSchema(field~ : String, detail~ : String)
  LimitExceeded(field~ : String, value~ : Int64, limit~ : Int64)
  Signature(SignatureError)
  CatalogHashMismatch(expected~ : String, actual~ : String)
  CatalogRollback(catalog_version~ : Int64, min_catalog_version~ : Int64)
  DowngradeRejected(
    current_version~ : Int64,
    target_version~ : Int64,
    min_version~ : Int64,
  )
  UnknownVersion(version~ : Int64)
  CurrentIdentityMismatch(version~ : Int64, difference~ : IdentityDifference)
  InvalidMaxSteps(Int64)
  InvalidMaxDownloadBytes(Int64)
  NoRoute(effective_max_steps~ : Int64?)
  BudgetExceeded(minimum_bytes~ : Int64, max_download_bytes~ : Int64)
}

///|
pub extend CatalogError with Eq::{equal, not_equal}

///|
pub extend CatalogError with @debug.Debug::{to_repr}

///|
#derive(Debug)
priv struct CatalogContentRepr {
  size : Int64
  hash : String
}

///|
#derive(Debug)
priv struct CatalogReleaseRepr {
  version : Int64
  label : String
  content : CatalogContentRepr
}

///|
#derive(Debug)
priv struct CatalogPatchRepr {
  from_version : Int64
  to_version : Int64
  patch : CatalogContentRepr
  manifest_sha256 : String?
  uri : String?
}

///|
/// Release entry declared in a ReleaseCatalog.
#derive(Eq)
pub(all) struct CatalogRelease {
  version : Int64
  label : String
  content : ContentIdentity
}

///|
pub extend CatalogRelease with Eq::{equal, not_equal}

///|
pub impl @debug.Debug for CatalogRelease with fn to_repr(self) {
  let repr : CatalogReleaseRepr = {
    version: self.version,
    label: self.label,
    content: { size: self.content.size, hash: self.content.hash, },
  }
  @debug.Repr(repr)
}

///|
pub extend CatalogRelease with @debug.Debug::{to_repr}

///|
/// Directed patch edge declared in a ReleaseCatalog.
#derive(Eq)
pub(all) struct CatalogPatch {
  from_version : Int64
  to_version : Int64
  patch : ContentIdentity
  manifest_sha256 : String?
  uri : String?
}

///|
pub extend CatalogPatch with Eq::{equal, not_equal}

///|
pub impl @debug.Debug for CatalogPatch with fn to_repr(self) {
  let repr : CatalogPatchRepr = {
    from_version: self.from_version,
    to_version: self.to_version,
    patch: { size: self.patch.size, hash: self.patch.hash, },
    manifest_sha256: self.manifest_sha256,
    uri: self.uri,
  }
  @debug.Repr(repr)
}

///|
pub extend CatalogPatch with @debug.Debug::{to_repr}

///|
/// Schema-1 release catalog describing releases, anti-downgrade floor, and patch graph.
#derive(Eq, Debug)
pub struct ReleaseCatalog {
  channel : String
  catalog_version : Int64
  min_version : Int64
  releases : ReadOnlyArray[CatalogRelease]
  patches : ReadOnlyArray[CatalogPatch]
}

///|
pub extend ReleaseCatalog with Eq::{equal, not_equal}

///|
pub extend ReleaseCatalog with @debug.Debug::{to_repr}

///|
fn catalog_has_unpaired_surrogate(text : String) -> Bool {
  let len = text.length()
  let mut i = 0
  while i < len {
    let unit = text[i].to_int()
    if unit >= 0xD800 && unit <= 0xDBFF {
      if i + 1 >= len {
        return true
      }
      let next = text[i + 1].to_int()
      if next < 0xDC00 || next > 0xDFFF {
        return true
      }
      i = i + 2
    } else if unit >= 0xDC00 && unit <= 0xDFFF {
      return true
    } else {
      i = i + 1
    }
  }
  false
}

///|
fn catalog_has_control_chars(text : String) -> Bool {
  for ch in text {
    let code = ch.to_int()
    if (code >= 0 && code <= 0x1f) || (code >= 0x7f && code <= 0x9f) {
      return true
    }
  }
  false
}

///|
fn catalog_validate_channel(channel : String) -> Result[Unit, CatalogError] {
  if catalog_has_unpaired_surrogate(channel) {
    return Err(
      InvalidSchema(
        field="channel",
        detail="catalog schema: channel contains unpaired UTF-16 surrogate",
      ),
    )
  }
  let raw = @utf8.encode(channel[:])
  if raw.length() == 0 || raw.length() > catalog_max_channel_bytes {
    return Err(
      InvalidSchema(
        field="channel",
        detail="catalog schema: channel must be 1..\{catalog_max_channel_bytes} ASCII bytes",
      ),
    )
  }
  for byte in raw {
    let code = byte.to_int()
    let ok = (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      code == 46 ||
      code == 95 ||
      code == 45
    if !ok {
      return Err(
        InvalidSchema(
          field="channel",
          detail="catalog schema: channel must contain only ASCII [A-Za-z0-9._-]",
        ),
      )
    }
  }
  Ok(())
}

///|
fn catalog_validate_label(
  label : String,
  field : String,
) -> Result[Unit, CatalogError] {
  if catalog_has_unpaired_surrogate(label) {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " contains unpaired UTF-16 surrogate",
      ),
    )
  }
  let raw = @utf8.encode(label[:])
  if raw.length() == 0 || raw.length() > catalog_max_label_bytes {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " must be 1..\{catalog_max_label_bytes} UTF-8 bytes",
      ),
    )
  }
  if catalog_has_control_chars(label) {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " must not contain control characters",
      ),
    )
  }
  Ok(())
}

///|
fn catalog_validate_sha256(
  hash : String,
  field : String,
) -> Result[Unit, CatalogError] {
  let encoded = @utf8.encode(hash[:])
  if encoded.length() != 64 {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " + field + " requires 64 lowercase hex digits",
      ),
    )
  }
  for byte in encoded {
    let code = byte.to_int()
    if !((code >= 48 && code <= 57) || (code >= 97 && code <= 102)) {
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " + field + " requires lowercase hex digits",
        ),
      )
    }
  }
  Ok(())
}

///|
fn catalog_hex_nibble_any(byte : Byte) -> Int32? {
  let code = byte.to_int()
  if code >= 48 && code <= 57 {
    Some(code - 48)
  } else if code >= 97 && code <= 102 {
    Some(code - 97 + 10)
  } else if code >= 65 && code <= 70 {
    Some(code - 65 + 10)
  } else {
    None
  }
}

///|
fn catalog_percent_decode_bytes(raw : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let n = raw.length()
  let mut i = 0
  while i < n {
    if raw[i] == b'%' && i + 2 < n {
      match
        (catalog_hex_nibble_any(raw[i + 1]), catalog_hex_nibble_any(raw[i + 2])) {
        (Some(hi), Some(lo)) => {
          out.push(((hi << 4) | lo).to_byte())
          i = i + 3
          continue
        }
        _ => ()
      }
    }
    out.push(raw[i])
    i = i + 1
  }
  Bytes::from_array(out)
}

///|
fn catalog_has_dotdot_segment(raw : Bytes) -> Bool {
  let n = raw.length()
  let mut seg_start = 0
  let mut i = 0
  while i <= n {
    let is_sep = if i == n {
      true
    } else {
      let b = raw[i]
      b == b'/' || b == b'\\' || b == b'?' || b == b'#' || b == b';'
    }
    if is_sep {
      if i - seg_start == 2 &&
        raw[seg_start] == b'.' &&
        raw[seg_start + 1] == b'.' {
        return true
      }
      seg_start = i + 1
    }
    i = i + 1
  }
  false
}

///|
fn catalog_has_unsafe_uri_chars(text : String) -> Bool {
  for ch in text {
    let code = ch.to_int()
    if (code >= 0 && code <= 0x1F) ||
      (code >= 0x7F && code <= 0x9F) ||
      code == 0x00A0 ||
      code == 0x00AD ||
      code == 0x034F ||
      code == 0x061C ||
      code == 0x1680 ||
      code == 0x180E ||
      (code >= 0x2000 && code <= 0x200F) ||
      code == 0x2024 ||
      code == 0x2025 ||
      code == 0x2026 ||
      (code >= 0x2028 && code <= 0x202F) ||
      (code >= 0x205F && code <= 0x206F) ||
      code == 0x2215 ||
      code == 0x29F8 ||
      code == 0x29F9 ||
      code == 0x3000 ||
      code == 0x3002 ||
      code == 0xFE52 ||
      code == 0xFE68 ||
      code == 0xFEFF ||
      code == 0xFF0E ||
      code == 0xFF0F ||
      code == 0xFF1A ||
      code == 0xFF3C ||
      (code >= 0xFFF0 && code <= 0xFFFF) {
      return true
    }
  }
  false
}

///|
fn catalog_bytes_have_control_or_backslash(raw : Bytes) -> Bool {
  let n = raw.length()
  for i = 0; i < n; i = i + 1 {
    let b = raw[i]
    let code = b.to_int()
    if code < 0x20 || code == 0x7F || b == b'\\' {
      return true
    }
    if code == 0xC2 && i + 1 < n {
      let next = raw[i + 1].to_int()
      if next >= 0x80 && next <= 0x9F {
        return true
      }
    }
  }
  false
}

///|
fn catalog_bytes_has_prefix(raw : Bytes, prefix : Bytes) -> Bool {
  if raw.length() < prefix.length() {
    return false
  }
  for i = 0; i < prefix.length(); i = i + 1 {
    if raw[i] != prefix[i] {
      return false
    }
  }
  true
}

///|
fn catalog_is_ascii_hex(code : Int32) -> Bool {
  (code >= 48 && code <= 57) ||
  (code >= 65 && code <= 70) ||
  (code >= 97 && code <= 102)
}

///|
fn catalog_validate_port(raw : Bytes, start : Int32, end : Int32) -> Bool {
  let len = end - start
  if len < 1 || len > 5 || raw[start] == b'0' {
    return false
  }
  let mut val = 0
  for i = start; i < end; i = i + 1 {
    let d = raw[i].to_int() - 48
    if d < 0 || d > 9 {
      return false
    }
    val = val * 10 + d
  }
  val >= 1 && val <= 65535
}

///|
fn catalog_validate_ipv4(raw : Bytes, start : Int32, end : Int32) -> Bool {
  if start >= end {
    return false
  }
  let mut octets = 0
  let mut seg_start = start
  for i = start; i <= end; i = i + 1 {
    if i == end || raw[i] == b'.' {
      let seg_len = i - seg_start
      if seg_len < 1 || seg_len > 3 {
        return false
      }
      if seg_len > 1 && raw[seg_start] == b'0' {
        return false
      }
      let mut val = 0
      for j = seg_start; j < i; j = j + 1 {
        let d = raw[j].to_int() - 48
        if d < 0 || d > 9 {
          return false
        }
        val = val * 10 + d
      }
      if val > 255 {
        return false
      }
      octets = octets + 1
      seg_start = i + 1
    }
  }
  octets == 4
}

///|
fn catalog_validate_ipv6_literal(
  raw : Bytes,
  start : Int32,
  end : Int32,
) -> Bool {
  if start >= end {
    return false
  }
  // Reject leading or trailing single ':'.
  if raw[start] == b':' && (start + 1 >= end || raw[start + 1] != b':') {
    return false
  }
  if raw[end - 1] == b':' && (end - 2 < start || raw[end - 2] != b':') {
    return false
  }
  let mut saw_colon = false
  let mut double_colon = false
  let mut groups = 0
  let mut i = start
  while i < end {
    if raw[i] == b':' {
      saw_colon = true
      if i + 1 < end && raw[i + 1] == b':' {
        if double_colon {
          return false
        }
        if i + 2 < end && raw[i + 2] == b':' {
          return false
        }
        double_colon = true
        i = i + 2
      } else {
        i = i + 1
      }
      continue
    }
    let piece_start = i
    let mut has_dot = false
    while i < end && raw[i] != b':' {
      if raw[i] == b'.' {
        has_dot = true
      }
      i = i + 1
    }
    if has_dot {
      // Embedded IPv4 must be the final piece.
      if i != end || !catalog_validate_ipv4(raw, piece_start, i) {
        return false
      }
      groups = groups + 2
    } else {
      let piece_len = i - piece_start
      if piece_len < 1 || piece_len > 4 {
        return false
      }
      for j = piece_start; j < i; j = j + 1 {
        if !catalog_is_ascii_hex(raw[j].to_int()) {
          return false
        }
      }
      groups = groups + 1
    }
  }
  if !saw_colon {
    return false
  }
  if double_colon {
    groups <= 7
  } else {
    groups == 8
  }
}

///|
fn catalog_validate_dns_host(raw : Bytes, start : Int32, end : Int32) -> Bool {
  let len = end - start
  if len < 1 || len > 253 {
    return false
  }
  let mut seg_start = start
  let mut all_digits = true
  for i = start; i <= end; i = i + 1 {
    if i == end || raw[i] == b'.' {
      let seg_len = i - seg_start
      if seg_len < 1 || seg_len > 63 {
        return false
      }
      if raw[seg_start] == b'-' || raw[i - 1] == b'-' {
        return false
      }
      seg_start = i + 1
    } else {
      let code = raw[i].to_int()
      let is_digit = code >= 48 && code <= 57
      let is_alpha = (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
      let is_hyphen = code == 45
      if !is_digit && !is_alpha && !is_hyphen {
        return false
      }
      if !is_digit {
        all_digits = false
      }
    }
  }
  if all_digits {
    catalog_validate_ipv4(raw, start, end)
  } else {
    true
  }
}

///|
fn catalog_validate_http_authority(raw : Bytes, prefix_len : Int32) -> Bool {
  let n = raw.length()
  let mut auth_end = n
  for i = prefix_len; i < n; i = i + 1 {
    let b = raw[i]
    if b == b'/' || b == b'?' || b == b'#' {
      auth_end = i
      break
    }
  }
  if auth_end <= prefix_len {
    return false
  }
  if raw[prefix_len] == b'[' {
    let mut close_idx = -1
    for i = prefix_len + 1; i < auth_end; i = i + 1 {
      if raw[i] == b']' {
        close_idx = i
        break
      }
    }
    if close_idx <= prefix_len + 1 {
      return false
    }
    if !catalog_validate_ipv6_literal(raw, prefix_len + 1, close_idx) {
      return false
    }
    if close_idx + 1 == auth_end {
      true
    } else if raw[close_idx + 1] == b':' {
      catalog_validate_port(raw, close_idx + 2, auth_end)
    } else {
      false
    }
  } else {
    let mut colon_idx = -1
    for i = prefix_len; i < auth_end; i = i + 1 {
      let b = raw[i]
      if b == b':' {
        if colon_idx != -1 {
          return false
        }
        colon_idx = i
      } else if b == b'[' || b == b']' {
        return false
      }
    }
    let host_end = if colon_idx == -1 { auth_end } else { colon_idx }
    if !catalog_validate_dns_host(raw, prefix_len, host_end) {
      return false
    }
    if colon_idx != -1 {
      catalog_validate_port(raw, colon_idx + 1, auth_end)
    } else {
      true
    }
  }
}

///|
fn catalog_validate_relative_posix_bytes(raw : Bytes) -> Bool {
  let n = raw.length()
  if n == 0 || raw[0] == b'/' || raw[n - 1] == b'/' {
    return false
  }
  let mut seg_start = 0
  for i = 0; i <= n; i = i + 1 {
    if i < n {
      let b = raw[i]
      if b.to_int() <= 0x20 || b == b':' || b == b'\\' || b == b'?' || b == b'#' {
        return false
      }
    }
    if i == n || raw[i] == b'/' {
      let seg_len = i - seg_start
      if seg_len == 0 {
        return false
      }
      if seg_len == 1 && raw[seg_start] == b'.' {
        return false
      }
      if seg_len == 2 && raw[seg_start] == b'.' && raw[seg_start + 1] == b'.' {
        return false
      }
      seg_start = i + 1
    }
  }
  true
}

///|
fn catalog_validate_uri(
  uri : String,
  field : String,
) -> Result[Unit, CatalogError] {
  if catalog_has_unpaired_surrogate(uri) {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " contains unpaired UTF-16 surrogate",
      ),
    )
  }
  let raw = @utf8.encode(uri[:])
  if raw.length() == 0 || raw.length() > catalog_max_uri_bytes {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " must be 1..\{catalog_max_uri_bytes} UTF-8 bytes",
      ),
    )
  }
  if catalog_has_unsafe_uri_chars(uri) {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " must not contain control, invisible, or confusable characters",
      ),
    )
  }
  if catalog_bytes_have_control_or_backslash(raw) {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " must not contain control characters or backslashes",
      ),
    )
  }
  if catalog_has_dotdot_segment(raw) {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " must not contain '..' path traversal",
      ),
    )
  }
  let mut decoded = raw
  let mut fixed_point = false
  for _pass = 0; _pass < 4; _pass = _pass + 1 {
    let next = catalog_percent_decode_bytes(decoded)
    if next == decoded {
      fixed_point = true
      break
    }
    decoded = next
    if catalog_bytes_have_control_or_backslash(decoded) {
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " +
            field +
            " must not contain percent-encoded control characters or backslashes",
        ),
      )
    }
    let decoded_text = @utf8.decode(decoded[:], ignore_bom=false) catch {
      _ =>
        return Err(
          InvalidSchema(
            field~,
            detail="catalog schema: " +
              field +
              " contains invalid or overlong percent-encoded UTF-8",
          ),
        )
    }
    if catalog_has_unsafe_uri_chars(decoded_text) {
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " +
            field +
            " must not contain percent-encoded control, invisible, or confusable characters",
        ),
      )
    }
    if catalog_has_dotdot_segment(decoded) {
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " +
            field +
            " must not contain '..' path traversal",
        ),
      )
    }
  }
  if !fixed_point && catalog_percent_decode_bytes(decoded) != decoded {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " exceeds maximum percent-encoding nesting depth",
      ),
    )
  }
  let is_http = catalog_bytes_has_prefix(raw, b"http://")
  let is_https = catalog_bytes_has_prefix(raw, b"https://")
  if is_http || is_https {
    let prefix_len = if is_https { 8 } else { 7 }
    for byte in raw {
      if byte == b' ' ||
        byte == b'<' ||
        byte == b'>' ||
        byte == b'"' ||
        byte == b'`' ||
        byte == b'{' ||
        byte == b'}' ||
        byte == b'|' ||
        byte == b'^' {
        return Err(
          InvalidSchema(
            field~,
            detail="catalog schema: " +
              field +
              " URL contains disallowed whitespace or metacharacters",
          ),
        )
      }
    }
    if !catalog_validate_http_authority(raw, prefix_len) ||
      !catalog_validate_http_authority(decoded, prefix_len) {
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " + field + " has invalid HTTP(S) authority",
        ),
      )
    }
  } else if !catalog_validate_relative_posix_bytes(raw) ||
    !catalog_validate_relative_posix_bytes(decoded) {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " +
          field +
          " must be an http(s):// URL or strict relative POSIX path",
      ),
    )
  }
  Ok(())
}

///|
fn catalog_validate_and_build(
  channel : String,
  catalog_version : Int64,
  min_version : Int64,
  releases : Array[CatalogRelease],
  patches : Array[CatalogPatch],
) -> Result[ReleaseCatalog, CatalogError] {
  match catalog_validate_channel(channel) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if catalog_version < 1L {
    return Err(
      InvalidSchema(
        field="catalog_version",
        detail="catalog schema: catalog_version must be at least 1",
      ),
    )
  }
  if min_version < 0L {
    return Err(
      InvalidSchema(
        field="min_version",
        detail="catalog schema: min_version must be nonnegative",
      ),
    )
  }
  if releases.is_empty() {
    return Err(
      InvalidSchema(
        field="releases",
        detail="catalog schema: releases must not be empty",
      ),
    )
  }
  if releases.length() > catalog_max_releases {
    return Err(
      LimitExceeded(
        field="max_catalog_releases",
        value=releases.length().to_int64(),
        limit=catalog_max_releases.to_int64(),
      ),
    )
  }
  if patches.length() > catalog_max_patches {
    return Err(
      LimitExceeded(
        field="max_catalog_patches",
        value=patches.length().to_int64(),
        limit=catalog_max_patches.to_int64(),
      ),
    )
  }
  let seen_versions : Map[Int64, Unit] = Map([])
  let seen_labels : Map[String, Unit] = Map([])
  for i = 0; i < releases.length(); i = i + 1 {
    let rel = releases[i]
    let prefix = "releases[\{i}]"
    if rel.version < 1L {
      return Err(
        InvalidSchema(
          field=prefix + ".version",
          detail="catalog schema: release version must be at least 1",
        ),
      )
    }
    if seen_versions.get(rel.version) is Some(_) {
      return Err(
        InvalidSchema(
          field=prefix + ".version",
          detail="catalog schema: duplicate release version \{rel.version}",
        ),
      )
    }
    seen_versions[rel.version] = ()
    match catalog_validate_label(rel.label, prefix + ".label") {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    if seen_labels.get(rel.label) is Some(_) {
      return Err(
        InvalidSchema(
          field=prefix + ".label",
          detail="catalog schema: duplicate release label " + rel.label,
        ),
      )
    }
    seen_labels[rel.label] = ()
    if rel.content.size < 0L {
      return Err(
        InvalidSchema(
          field=prefix + ".size_bytes",
          detail="catalog schema: release size_bytes must be nonnegative",
        ),
      )
    }
    match catalog_validate_sha256(rel.content.hash, prefix + ".sha256") {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  for i = 0; i < patches.length(); i = i + 1 {
    let p = patches[i]
    let prefix = "patches[\{i}]"
    if seen_versions.get(p.from_version) is None {
      return Err(
        InvalidSchema(
          field=prefix + ".from_version",
          detail="catalog schema: patch from_version \{p.from_version} is not in releases",
        ),
      )
    }
    if seen_versions.get(p.to_version) is None {
      return Err(
        InvalidSchema(
          field=prefix + ".to_version",
          detail="catalog schema: patch to_version \{p.to_version} is not in releases",
        ),
      )
    }
    if p.from_version == p.to_version {
      return Err(
        InvalidSchema(
          field=prefix + ".to_version",
          detail="catalog schema: patch from_version and to_version must differ",
        ),
      )
    }
    if p.patch.size < catalog_min_patch_bytes {
      return Err(
        InvalidSchema(
          field=prefix + ".patch_size_bytes",
          detail="catalog schema: patch_size_bytes must be at least \{catalog_min_patch_bytes}",
        ),
      )
    }
    match catalog_validate_sha256(p.patch.hash, prefix + ".patch_sha256") {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    match p.manifest_sha256 {
      Some(mhash) =>
        match catalog_validate_sha256(mhash, prefix + ".manifest_sha256") {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      None => ()
    }
    match p.uri {
      Some(u) =>
        match catalog_validate_uri(u, prefix + ".uri") {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      None => ()
    }
  }
  Ok({
    channel,
    catalog_version,
    min_version,
    releases: ReadOnlyArray::makei(releases.length(), i => releases[i]),
    patches: ReadOnlyArray::makei(patches.length(), i => patches[i]),
  })
}

///|
/// Construct and validate a ReleaseCatalog programmatically, enforcing
/// serialized size <= `max_catalog_file_bytes`.
pub fn ReleaseCatalog::new(
  channel : String,
  catalog_version : Int64,
  min_version : Int64,
  releases : Array[CatalogRelease],
  patches : Array[CatalogPatch],
) -> Result[ReleaseCatalog, CatalogError] {
  let catalog = match
    catalog_validate_and_build(
      channel, catalog_version, min_version, releases, patches,
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let serialized_size = catalog.to_json_bytes().length().to_int64()
  let cap = max_catalog_file_bytes.to_int64()
  if serialized_size > cap {
    return Err(
      LimitExceeded(
        field="max_catalog_file_bytes",
        value=serialized_size,
        limit=cap,
      ),
    )
  }
  Ok(catalog)
}

///|
/// Serialize a ReleaseCatalog to deterministic canonical UTF-8 JSON bytes
/// with exact 64-bit integer formatting and trailing newline.
pub fn ReleaseCatalog::to_json_bytes(self : ReleaseCatalog) -> Bytes {
  let out = StringBuilder()
  out.write_string(
    "{\"schema\":1,\"type\":\"moonbsdiff-release-catalog\",\"channel\":",
  )
  out.write_string(@json.Json::string(self.channel).stringify())
  out.write_string(",\"catalog_version\":")
  out.write_string(self.catalog_version.to_string())
  out.write_string(",\"min_version\":")
  out.write_string(self.min_version.to_string())
  out.write_string(",\"releases\":[")
  for i = 0; i < self.releases.length(); i = i + 1 {
    if i > 0 {
      out.write_char(',')
    }
    let rel = self.releases[i]
    out.write_string("{\"version\":")
    out.write_string(rel.version.to_string())
    out.write_string(",\"label\":")
    out.write_string(@json.Json::string(rel.label).stringify())
    out.write_string(",\"size_bytes\":")
    out.write_string(rel.content.size.to_string())
    out.write_string(",\"sha256\":")
    out.write_string(@json.Json::string(rel.content.hash).stringify())
    out.write_char('}')
  }
  out.write_string("],\"patches\":[")
  for i = 0; i < self.patches.length(); i = i + 1 {
    if i > 0 {
      out.write_char(',')
    }
    let p = self.patches[i]
    out.write_string("{\"from_version\":")
    out.write_string(p.from_version.to_string())
    out.write_string(",\"to_version\":")
    out.write_string(p.to_version.to_string())
    out.write_string(",\"patch_size_bytes\":")
    out.write_string(p.patch.size.to_string())
    out.write_string(",\"patch_sha256\":")
    out.write_string(@json.Json::string(p.patch.hash).stringify())
    match p.manifest_sha256 {
      Some(mhash) => {
        out.write_string(",\"manifest_sha256\":")
        out.write_string(@json.Json::string(mhash).stringify())
      }
      None => ()
    }
    match p.uri {
      Some(u) => {
        out.write_string(",\"uri\":")
        out.write_string(@json.Json::string(u).stringify())
      }
      None => ()
    }
    out.write_char('}')
  }
  out.write_string("]}\n")
  @utf8.encode(out.to_string()[:])
}

///|
fn catalog_parse_object(
  value : @json.Json,
  required_keys : Array[String],
  optional_keys : Array[String],
  context : String,
) -> Result[Map[String, @json.Json], CatalogError] {
  let fields = match value {
    @json.Object(fields) => fields
    _ =>
      return Err(
        InvalidSchema(
          field=context,
          detail="catalog schema: " + context + " must be an object",
        ),
      )
  }
  for key in required_keys {
    if fields.get(key) is None {
      let field = if context == "root" { key } else { context + "." + key }
      return Err(
        InvalidSchema(field~, detail="catalog schema: missing " + field),
      )
    }
  }
  for key, _ in fields {
    if !required_keys.contains(key) && !optional_keys.contains(key) {
      let field = if context == "root" { key } else { context + "." + key }
      return Err(
        InvalidSchema(field~, detail="catalog schema: unknown field " + field),
      )
    }
  }
  Ok(fields)
}

///|
fn catalog_parse_string(
  value : @json.Json,
  field : String,
) -> Result[String, CatalogError] {
  match value {
    @json.String(text) => Ok(text)
    _ =>
      Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " + field + " must be a string",
        ),
      )
  }
}

///|
fn catalog_parse_nonneg_int64(
  value : @json.Json,
  field : String,
  min_value : Int64,
) -> Result[Int64, CatalogError] {
  let raw_str = match value {
    @json.Number(_, repr=Some(text)) => text
    _ =>
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " + field + " must be an integer",
        ),
      )
  }
  let raw = @utf8.encode(raw_str[:])
  if raw.length() == 0 {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " + field + " must be an integer",
      ),
    )
  }
  if raw.length() > 1 && raw[0] == b'0' {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " + field + " must not have leading zeros",
      ),
    )
  }
  let mut acc = 0L
  for byte in raw {
    let digit = byte.to_int() - 48
    if digit < 0 || digit > 9 {
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " +
            field +
            " must be a nonnegative base-10 integer",
        ),
      )
    }
    let d64 = digit.to_int64()
    if acc > (9223372036854775807L - d64) / 10L {
      return Err(
        InvalidSchema(
          field~,
          detail="catalog schema: " + field + " overflows Int64",
        ),
      )
    }
    acc = acc * 10L + d64
  }
  if acc < min_value {
    return Err(
      InvalidSchema(
        field~,
        detail="catalog schema: " + field + " must be at least \{min_value}",
      ),
    )
  }
  Ok(acc)
}

///|
/// Parse and strictly validate a schema-1 ReleaseCatalog JSON document.
pub fn ReleaseCatalog::from_json_bytes(
  data : Bytes,
) -> Result[ReleaseCatalog, CatalogError] {
  let size = data.length().to_int64()
  let cap = max_catalog_file_bytes.to_int64()
  if size > cap {
    return Err(
      LimitExceeded(field="max_catalog_file_bytes", value=size, limit=cap),
    )
  }
  if data is [0xef, 0xbb, 0xbf, ..] {
    return Err(InvalidEncoding)
  }
  let text = @utf8.decode(data[:], ignore_bom=false) catch {
    _ => return Err(InvalidEncoding)
  }
  if json_exceeds_max_depth(text[:], 8) {
    return Err(InvalidJson(field=None, detail="nesting depth limit exceeded"))
  }
  let json = @json.parse(
    text[:],
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => {
      let field = json_duplicate_key_field(error)
      return Err(InvalidJson(field~, detail=@debug.to_string(error)))
    }
  }
  let root = match
    catalog_parse_object(
      json,
      [
        "schema", "type", "channel", "catalog_version", "min_version", "releases",
        "patches",
      ],
      [],
      "root",
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if !(root["schema"] is @json.Number(_, repr=Some("1"))) {
    return Err(
      InvalidSchema(field="schema", detail="catalog schema: expected integer 1"),
    )
  }
  let doc_type = match catalog_parse_string(root["type"], "type") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if doc_type != "moonbsdiff-release-catalog" {
    return Err(
      InvalidSchema(
        field="type",
        detail="catalog schema: expected type moonbsdiff-release-catalog",
      ),
    )
  }
  let channel = match catalog_parse_string(root["channel"], "channel") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let catalog_version = match
    catalog_parse_nonneg_int64(root["catalog_version"], "catalog_version", 1L) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let min_version = match
    catalog_parse_nonneg_int64(root["min_version"], "min_version", 0L) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let raw_releases = match root["releases"] {
    @json.Array(items) => items
    _ =>
      return Err(
        InvalidSchema(
          field="releases",
          detail="catalog schema: releases must be an array",
        ),
      )
  }
  if raw_releases.length() > catalog_max_releases {
    return Err(
      LimitExceeded(
        field="max_catalog_releases",
        value=raw_releases.length().to_int64(),
        limit=catalog_max_releases.to_int64(),
      ),
    )
  }
  let raw_patches = match root["patches"] {
    @json.Array(items) => items
    _ =>
      return Err(
        InvalidSchema(
          field="patches",
          detail="catalog schema: patches must be an array",
        ),
      )
  }
  if raw_patches.length() > catalog_max_patches {
    return Err(
      LimitExceeded(
        field="max_catalog_patches",
        value=raw_patches.length().to_int64(),
        limit=catalog_max_patches.to_int64(),
      ),
    )
  }
  let releases : Array[CatalogRelease] = []
  for i = 0; i < raw_releases.length(); i = i + 1 {
    let ctx = "releases[\{i}]"
    let obj = match
      catalog_parse_object(
        raw_releases[i],
        ["version", "label", "size_bytes", "sha256"],
        [],
        ctx,
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let version = match
      catalog_parse_nonneg_int64(obj["version"], ctx + ".version", 1L) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let label = match catalog_parse_string(obj["label"], ctx + ".label") {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let size_bytes = match
      catalog_parse_nonneg_int64(obj["size_bytes"], ctx + ".size_bytes", 0L) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let sha256 = match catalog_parse_string(obj["sha256"], ctx + ".sha256") {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    releases.push({
      version,
      label,
      content: { size: size_bytes, hash: sha256, },
    })
  }
  let patches : Array[CatalogPatch] = []
  for i = 0; i < raw_patches.length(); i = i + 1 {
    let ctx = "patches[\{i}]"
    let obj = match
      catalog_parse_object(
        raw_patches[i],
        ["from_version", "to_version", "patch_size_bytes", "patch_sha256"],
        ["manifest_sha256", "uri"],
        ctx,
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let from_version = match
      catalog_parse_nonneg_int64(obj["from_version"], ctx + ".from_version", 1L) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let to_version = match
      catalog_parse_nonneg_int64(obj["to_version"], ctx + ".to_version", 1L) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let patch_size_bytes = match
      catalog_parse_nonneg_int64(
        obj["patch_size_bytes"],
        ctx + ".patch_size_bytes",
        catalog_min_patch_bytes,
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let patch_sha256 = match
      catalog_parse_string(obj["patch_sha256"], ctx + ".patch_sha256") {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    let manifest_sha256 = match obj.get("manifest_sha256") {
      Some(val) =>
        match catalog_parse_string(val, ctx + ".manifest_sha256") {
          Ok(s) => Some(s)
          Err(err) => return Err(err)
        }
      None => None
    }
    let uri = match obj.get("uri") {
      Some(val) =>
        match catalog_parse_string(val, ctx + ".uri") {
          Ok(s) => Some(s)
          Err(err) => return Err(err)
        }
      None => None
    }
    patches.push({
      from_version,
      to_version,
      patch: { size: patch_size_bytes, hash: patch_sha256, },
      manifest_sha256,
      uri,
    })
  }
  catalog_validate_and_build(
    channel, catalog_version, min_version, releases, patches,
  )
}

///|
/// Detached domain-separated Ed25519 signature over a ReleaseCatalog JSON document.
#derive(Eq, Debug)
pub struct CatalogSignature {
  priv key_id : String
  priv catalog_sha256 : String
  priv signature_raw : Bytes
  priv signature_hex : String
}

///|
pub extend CatalogSignature with Eq::{equal, not_equal}

///|
pub extend CatalogSignature with @debug.Debug::{to_repr}

///|
/// Parse a strict schema-1 detached catalog signature JSON envelope.
pub fn CatalogSignature::from_json_bytes(
  data : Bytes,
) -> Result[CatalogSignature, SignatureError] {
  let fields = match
    parse_signature_envelope(
      data,
      max_signature_file_bytes,
      "max_signature_file_bytes",
      [
        "schema_version", "format", "algorithm", "key_id", "catalog_sha256", "signature",
      ],
      "moonbsdiff-catalog-signature",
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (key_id, _) = match parse_lowercase_hex(fields["key_id"], "key_id", 16) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (catalog_sha256, _) = match
    parse_lowercase_hex(fields["catalog_sha256"], "catalog_sha256", 64) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (signature_hex, signature_raw) = match
    parse_lowercase_hex(fields["signature"], "signature", 128) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match validate_raw_signature_format(signature_raw[:]) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok({ key_id, catalog_sha256, signature_raw, signature_hex, })
}

///|
pub fn CatalogSignature::to_json_bytes(self : CatalogSignature) -> Bytes {
  encode_envelope_json({
    "schema_version": @json.Json::number(1.0),
    "format": @json.Json::string("moonbsdiff-catalog-signature"),
    "algorithm": @json.Json::string("ed25519"),
    "key_id": @json.Json::string(self.key_id),
    "catalog_sha256": @json.Json::string(self.catalog_sha256),
    "signature": @json.Json::string(self.signature_hex),
  })
}

///|
pub fn CatalogSignature::key_id(self : CatalogSignature) -> String {
  self.key_id
}

///|
pub fn CatalogSignature::catalog_sha256(self : CatalogSignature) -> String {
  self.catalog_sha256
}

///|
pub fn CatalogSignature::signature_bytes(self : CatalogSignature) -> Bytes {
  self.signature_raw
}

///|
pub fn CatalogSignature::signature_hex(self : CatalogSignature) -> String {
  self.signature_hex
}

///|
/// Validate ReleaseCatalog schema first, then sign exact catalog bytes with
/// catalog-domain-separated Ed25519.
pub fn PrivateKey::sign_catalog(
  self : PrivateKey,
  catalog_bytes : Bytes,
) -> Result[CatalogSignature, CatalogError] {
  match ReleaseCatalog::from_json_bytes(catalog_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let payload = catalog_signature_domain + catalog_bytes
  let sig_raw = @spec.Signer::sign(self.inner, payload[:])
  match validate_raw_signature_format(sig_raw[:]) {
    Ok(_) => ()
    Err(err) => return Err(Signature(err))
  }
  Ok({
    key_id: self.pub_key.key_id,
    catalog_sha256: @manifest_support.sha256_hex(catalog_bytes),
    signature_raw: sig_raw,
    signature_hex: @manifest_support.digest_hex(sig_raw),
  })
}

///|
/// Proof-carrying release catalog whose Ed25519 signature, schema, and optional
/// anti-replay version floor were verified by a TrustStore.
#derive(Eq, Debug)
pub struct VerifiedCatalog {
  catalog : ReleaseCatalog
  catalog_sha256 : String
  signer_key_id : String
}

///|
pub extend VerifiedCatalog with Eq::{equal, not_equal}

///|
pub extend VerifiedCatalog with @debug.Debug::{to_repr}

///|
fn catalog_verify_raw_signature(
  catalog_bytes : Bytes,
  sig_bytes : Bytes,
  public_key : PublicKey,
) -> Result[Unit, SignatureError] {
  match validate_raw_signature_format(sig_bytes[:]) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if !validate_canonical_ed25519_point(public_key.raw[:]) {
    return Err(
      InvalidPublicKey(
        detail="invalid, non-canonical, off-curve, or small-order Ed25519 public key",
      ),
    )
  }
  let ed_pk = @ed25519.PublicKey::new(public_key.raw[:]) catch {
    @spec.Size(want~, got~) =>
      return Err(InvalidKeyLength(expected=want, actual=got))
    @spec.Tag | @spec.Weak =>
      return Err(InvalidPublicKey(detail="invalid Ed25519 public key"))
  }
  let payload = catalog_signature_domain + catalog_bytes
  if @spec.Verifier::verify(ed_pk, payload[:], sig_bytes[:]) {
    Ok(())
  } else {
    Err(VerificationFailed)
  }
}

///|
/// Verify the catalog's Ed25519 signature against this TrustStore FIRST,
/// then parse and validate the ReleaseCatalog schema, and finally enforce
/// `catalog.catalog_version >= min_catalog_version` when provided.
pub fn TrustStore::verify_catalog(
  self : TrustStore,
  catalog_bytes : Bytes,
  sig : CatalogSignature,
  min_catalog_version? : Int64,
) -> Result[VerifiedCatalog, CatalogError] {
  let size = catalog_bytes.length().to_int64()
  let cap = max_catalog_file_bytes.to_int64()
  if size > cap {
    return Err(
      LimitExceeded(field="max_catalog_file_bytes", value=size, limit=cap),
    )
  }
  let public_key = match self.by_id.get(sig.key_id) {
    Some(pk) => pk
    None =>
      return Err(
        Signature(
          KeyIdMismatch(
            expected=catalog_join_key_ids(self.key_ids),
            actual=sig.key_id,
          ),
        ),
      )
  }
  let actual_hash = @manifest_support.sha256_hex(catalog_bytes)
  if actual_hash != sig.catalog_sha256 {
    return Err(
      CatalogHashMismatch(expected=sig.catalog_sha256, actual=actual_hash),
    )
  }
  match
    catalog_verify_raw_signature(catalog_bytes, sig.signature_raw, public_key) {
    Ok(_) => ()
    Err(err) => return Err(Signature(err))
  }
  let catalog = match ReleaseCatalog::from_json_bytes(catalog_bytes) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match min_catalog_version {
    Some(min_ver) =>
      if catalog.catalog_version < min_ver {
        return Err(
          CatalogRollback(
            catalog_version=catalog.catalog_version,
            min_catalog_version=min_ver,
          ),
        )
      }
    None => ()
  }
  Ok({ catalog, catalog_sha256: actual_hash, signer_key_id: public_key.key_id, })
}

///|
/// Selected multi-hop patch route inside a VerifiedCatalog.
#derive(Eq, Debug)
pub struct CatalogRoutePlan {
  total_patch_bytes : Int64
  patch_indices : ReadOnlyArray[Int32]
  target : CatalogRelease
}

///|
pub extend CatalogRoutePlan with Eq::{equal, not_equal}

///|
pub extend CatalogRoutePlan with @debug.Debug::{to_repr}

///|
/// Download and routing decision produced from a VerifiedCatalog.
#derive(Eq, Debug)
pub(all) enum CatalogUpdatePlan {
  UpToDate(CatalogRelease)
  Patches(CatalogRoutePlan)
  FullFile(CatalogRelease)
}

///|
pub extend CatalogUpdatePlan with Eq::{equal, not_equal}

///|
pub extend CatalogUpdatePlan with @debug.Debug::{to_repr}

///|
priv struct CatalogPlanEdge {
  index : Int32
  from_version : Int64
  to_version : Int64
  patch_bytes : Int64
}

///|
fn catalog_simple_path_depth(
  outgoing : Map[Int64, Array[CatalogPlanEdge]],
  edges_count : Int64,
) -> Int64 {
  let vertices : Map[Int64, Unit] = Map([])
  for from_v, edges in outgoing {
    vertices[from_v] = ()
    for edge in edges {
      vertices[edge.to_version] = ()
    }
  }
  edges_count.min((vertices.length().to_int64() - 1L).max(0L))
}

///|
fn catalog_plan_steps(
  outgoing : Map[Int64, Array[CatalogPlanEdge]],
  start : Int64,
  target : Int64,
  target_release : CatalogRelease,
  depth : Int64,
  track_hops : Bool,
) -> CatalogRoutePlan? {
  let state_key = (vertex, hops) => (vertex, if track_hops { hops } else { 0L })
  let initial = state_key(start, 0L)
  let queue = @priority_queue.from_array([(0L, 0L, 0L, start)])
  let scores = Map([(initial, (0L, 0L))])
  let predecessor : Map[(Int64, Int64), (CatalogPlanEdge, Int64)] = Map([])
  let mut sequence = 0L
  while queue.pop() is Some((cost_key, hops_key, _, vertex)) {
    let cost = -cost_key
    let hops = -hops_key
    let state = state_key(vertex, hops)
    if scores.get(state) != Some((cost, hops)) {
      continue
    }
    if vertex == target {
      let steps : Array[Int32] = []
      let mut at = state
      while at != initial {
        let (edge, prior_hops) = predecessor[at]
        steps.push(edge.index)
        at = state_key(edge.from_version, prior_hops)
      }
      return Some({
        total_patch_bytes: cost,
        patch_indices: ReadOnlyArray::makei(steps.length(), i => {
          steps[steps.length() - 1 - i]
        }),
        target: target_release,
      })
    }
    if hops == depth {
      continue
    }
    if outgoing.get(vertex) is Some(edges) {
      for edge in edges {
        let next_cost = cost + edge.patch_bytes
        let next_hops = hops + 1L
        let score = (next_cost, next_hops)
        let next_state = state_key(edge.to_version, next_hops)
        if scores.get(next_state) is Some(previous) && previous <= score {
          continue
        }
        scores[next_state] = score
        predecessor[next_state] = (edge, hops)
        sequence += 1L
        queue.push((-next_cost, -next_hops, -sequence, edge.to_version))
      }
    }
  }
  None
}

///|
/// Plan a fail-closed, anti-downgrade update from `current_version` to `target_version`
/// using this VerifiedCatalog.
pub fn VerifiedCatalog::plan_update(
  self : VerifiedCatalog,
  current_version : Int64,
  current_content : ContentIdentity,
  target_version : Int64,
  limits : @moonbsdiff.Limits,
  max_steps? : Int64,
  max_download_bytes? : Int64,
  allow_full? : Bool,
) -> Result[CatalogUpdatePlan, CatalogError] {
  match limits.validate() {
    Ok(_) => ()
    Err(err) => return Err(InvalidLimits(err))
  }
  if max_steps is Some(requested) && requested <= 0L {
    return Err(InvalidMaxSteps(requested))
  }
  if max_download_bytes is Some(budget) && budget < 0L {
    return Err(InvalidMaxDownloadBytes(budget))
  }
  let catalog = self.catalog
  if target_version < catalog.min_version || target_version < current_version {
    return Err(
      DowngradeRejected(
        current_version~,
        target_version~,
        min_version=catalog.min_version,
      ),
    )
  }
  let releases_by_version : Map[Int64, CatalogRelease] = Map([])
  for rel in catalog.releases {
    releases_by_version[rel.version] = rel
  }
  let current_release = match releases_by_version.get(current_version) {
    Some(r) => r
    None => return Err(UnknownVersion(version=current_version))
  }
  let target_release = match releases_by_version.get(target_version) {
    Some(r) => r
    None => return Err(UnknownVersion(version=target_version))
  }
  if current_content.size != current_release.content.size {
    return Err(
      CurrentIdentityMismatch(
        version=current_version,
        difference=Size(
          expected=current_release.content.size,
          actual=current_content.size,
        ),
      ),
    )
  }
  if current_content.hash != current_release.content.hash {
    return Err(
      CurrentIdentityMismatch(version=current_version, difference=Sha256),
    )
  }
  if current_version == target_version {
    return Ok(UpToDate(target_release))
  }
  if target_release.content.size > limits.max_output_bytes {
    return Err(
      LimitExceeded(
        field="max_output_bytes",
        value=target_release.content.size,
        limit=limits.max_output_bytes,
      ),
    )
  }
  if target_release.content.size > limits.max_new_bytes {
    return Err(
      LimitExceeded(
        field="max_new_bytes",
        value=target_release.content.size,
        limit=limits.max_new_bytes,
      ),
    )
  }
  let outgoing : Map[Int64, Array[CatalogPlanEdge]] = Map([])
  let mut filtered_count = 0L
  for i = 0; i < catalog.patches.length(); i = i + 1 {
    let p = catalog.patches[i]
    if p.patch.size > limits.max_patch_bytes {
      continue
    }
    if p.to_version < catalog.min_version ||
      p.to_version < current_version ||
      p.to_version <= p.from_version {
      continue
    }
    let from_rel = releases_by_version[p.from_version]
    let to_rel = releases_by_version[p.to_version]
    if from_rel.content.size > limits.max_old_bytes ||
      to_rel.content.size > limits.max_new_bytes ||
      to_rel.content.size > limits.max_output_bytes {
      continue
    }
    outgoing
    .get_or_init(p.from_version, () => [])
    .push({
      index: i,
      from_version: p.from_version,
      to_version: p.to_version,
      patch_bytes: p.patch.size,
    })
    filtered_count += 1L
  }
  let (depth, track_hops) = match max_steps {
    Some(requested) => {
      let simple_bound = catalog_simple_path_depth(outgoing, filtered_count)
      (requested.min(simple_bound), requested < simple_bound)
    }
    None => (filtered_count, false)
  }
  let best_route = catalog_plan_steps(
    outgoing, current_version, target_version, target_release, depth, track_hops,
  )
  let allow_full_fallback = allow_full.unwrap_or(false)
  if !allow_full_fallback {
    match best_route {
      Some(route) =>
        match max_download_bytes {
          Some(budget) if route.total_patch_bytes > budget =>
            Err(
              BudgetExceeded(
                minimum_bytes=route.total_patch_bytes,
                max_download_bytes=budget,
              ),
            )
          _ => Ok(Patches(route))
        }
      None => Err(NoRoute(effective_max_steps=max_steps.map(_ => depth)))
    }
  } else {
    let full_bytes = target_release.content.size
    match best_route {
      Some(route) if route.total_patch_bytes < full_bytes =>
        match max_download_bytes {
          Some(budget) if route.total_patch_bytes > budget =>
            Err(
              BudgetExceeded(
                minimum_bytes=route.total_patch_bytes,
                max_download_bytes=budget,
              ),
            )
          _ => Ok(Patches(route))
        }
      _ =>
        match max_download_bytes {
          Some(budget) if full_bytes > budget =>
            Err(
              BudgetExceeded(
                minimum_bytes=full_bytes,
                max_download_bytes=budget,
              ),
            )
          _ => Ok(FullFile(target_release))
        }
    }
  }
}
