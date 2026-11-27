///|
/// Domain separation prefix for detached Ed25519 directory manifest signatures.
pub const DIR_MANIFEST_SIGNATURE_DOMAIN : Bytes = b"moonbsdiff-dir-manifest-ed25519-v1\x00"

///|
/// Maximum accepted size of a serialized directory manifest JSON document (512 KiB).
pub let max_dir_manifest_bytes : Int32 = 524288

///|
let dir_max_path_length : Int32 = 1024

///|
let dir_max_blob_name_length : Int32 = 255

///|
let dir_manifest_type : String = "moonbsdiff-dir-manifest"

///|
let dir_signature_type : String = "moonbsdiff-dir-manifest-signature"

///|
let dir_i64_max : Int64 = 9223372036854775807L

///|
let dir_i32_max : Int64 = 2147483647L

///|
/// A file in an in-memory directory tree, identified by its POSIX relative path.
#derive(Eq, Debug)
pub(all) struct DirFileEntry {
  path : String
  bytes : Bytes
}

///|
pub extend DirFileEntry with Eq::{equal, not_equal}

///|
pub extend DirFileEntry with @debug.Debug::{to_repr}

///|
/// Errors from validating paths/trees, parsing/signing directory manifests,
/// diffing directory trees, or applying directory delta bundles.
#derive(Eq, Debug)
pub(all) enum DirDeltaError {
  InvalidPath(path~ : String, detail~ : String)
  DuplicatePath(String)
  PathCollision(a~ : String, b~ : String)
  InvalidBlobName(name~ : String, detail~ : String)
  DuplicateBlob(String)
  MissingBlob(String)
  UnexpectedBlob(String)
  InvalidLimits(@moonbsdiff.BsdiffError)
  LimitExceeded(field~ : String, value~ : Int64, limit~ : Int64)
  InvalidEncoding
  InvalidJson(field~ : String?, detail~ : String)
  InvalidSchema(field~ : String, detail~ : String)
  OldTreeMismatch(expected~ : String, actual~ : String)
  NewTreeMismatch(expected~ : String, actual~ : String)
  MissingOldFile(path~ : String)
  IdentityMismatch(
    path~ : String,
    object~ : ContentObject,
    difference~ : IdentityDifference,
  )
  ApplyError(path~ : String, error~ : @moonbsdiff.BsdiffError)
  Signature(SignatureError)
}

///|
pub extend DirDeltaError with Eq::{equal, not_equal}

///|
pub extend DirDeltaError with @debug.Debug::{to_repr}

///|
priv suberror DirDeltaFault {
  DirRejected(DirDeltaError)
}

///|
#derive(Debug)
priv struct DirIdentityRepr {
  size : Int64
  hash : String
}

///|
#derive(Debug)
priv enum DirEntryActionRepr {
  Unchanged(path~ : String, identity~ : DirIdentityRepr)
  Renamed(path~ : String, from_path~ : String, identity~ : DirIdentityRepr)
  Patched(
    path~ : String,
    from_path~ : String,
    old_identity~ : DirIdentityRepr,
    new_identity~ : DirIdentityRepr,
    patch_identity~ : DirIdentityRepr,
    blob_name~ : String,
  )
  Added(
    path~ : String,
    identity~ : DirIdentityRepr,
    blob_name~ : String,
    full_fallback~ : Bool,
  )
  Deleted(path~ : String, old_identity~ : DirIdentityRepr)
}

///|
fn dir_identity_repr(identity : ContentIdentity) -> DirIdentityRepr {
  { size: identity.size, hash: identity.hash, }
}

///|
/// Per-file action recorded in a schema 1 directory manifest.
#derive(Eq)
pub(all) enum DirEntryAction {
  Unchanged(path~ : String, identity~ : ContentIdentity)
  Renamed(path~ : String, from_path~ : String, identity~ : ContentIdentity)
  Patched(
    path~ : String,
    from_path~ : String,
    old_identity~ : ContentIdentity,
    new_identity~ : ContentIdentity,
    patch_identity~ : ContentIdentity,
    blob_name~ : String,
  )
  Added(
    path~ : String,
    identity~ : ContentIdentity,
    blob_name~ : String,
    full_fallback~ : Bool,
  )
  Deleted(path~ : String, old_identity~ : ContentIdentity)
}

///|
pub extend DirEntryAction with Eq::{equal, not_equal}

///|
pub impl @debug.Debug for DirEntryAction with fn to_repr(self) {
  let repr : DirEntryActionRepr = match self {
    Unchanged(path~, identity~) =>
      Unchanged(path~, identity=dir_identity_repr(identity))
    Renamed(path~, from_path~, identity~) =>
      Renamed(path~, from_path~, identity=dir_identity_repr(identity))
    Patched(
      path~,
      from_path~,
      old_identity~,
      new_identity~,
      patch_identity~,
      blob_name~,
    ) =>
      Patched(
        path~,
        from_path~,
        old_identity=dir_identity_repr(old_identity),
        new_identity=dir_identity_repr(new_identity),
        patch_identity=dir_identity_repr(patch_identity),
        blob_name~,
      )
    Added(path~, identity~, blob_name~, full_fallback~) =>
      Added(
        path~,
        identity=dir_identity_repr(identity),
        blob_name~,
        full_fallback~,
      )
    Deleted(path~, old_identity~) =>
      Deleted(path~, old_identity=dir_identity_repr(old_identity))
  }
  @debug.Debug::to_repr(repr)
}

///|
pub extend DirEntryAction with @debug.Debug::{to_repr}

///|
/// Schema 1 directory delta manifest describing a transition between two directory trees.
#derive(Eq, Debug)
pub struct DirManifest {
  old_tree_sha256 : String
  new_tree_sha256 : String
  old_file_count : Int32
  new_file_count : Int32
  old_total_bytes : Int64
  new_total_bytes : Int64
  delta_payload_bytes : Int64
  entries : ReadOnlyArray[DirEntryAction]
}

///|
pub extend DirManifest with Eq::{equal, not_equal}

///|
pub extend DirManifest with @debug.Debug::{to_repr}

///|
/// Named binary payload blob (`.patch` or `.full`) carried alongside a directory manifest.
#derive(Eq, Debug)
pub(all) struct DirBlob {
  name : String
  bytes : Bytes
}

///|
pub extend DirBlob with Eq::{equal, not_equal}

///|
pub extend DirBlob with @debug.Debug::{to_repr}

///|
/// Complete directory delta bundle: parsed manifest, canonical manifest JSON bytes, and payload blobs.
#derive(Eq, Debug)
pub struct DirDeltaBundle {
  manifest : DirManifest
  manifest_bytes : Bytes
  blobs : ReadOnlyArray[DirBlob]
}

///|
pub extend DirDeltaBundle with Eq::{equal, not_equal}

///|
pub extend DirDeltaBundle with @debug.Debug::{to_repr}

///|
/// Summary statistics of a directory delta manifest.
/// `added_count` counts all `Added` entries (including `full_fallback == true`),
/// while `full_fallback_count` counts the subset of `Added` entries with `full_fallback == true`.
#derive(Eq, Debug)
pub struct DirDeltaSummary {
  unchanged_count : Int32
  renamed_count : Int32
  patched_count : Int32
  added_count : Int32
  full_fallback_count : Int32
  deleted_count : Int32
  old_total_bytes : Int64
  new_total_bytes : Int64
  delta_payload_bytes : Int64
  old_tree_sha256 : String
  new_tree_sha256 : String
}

///|
pub extend DirDeltaSummary with Eq::{equal, not_equal}

///|
pub extend DirDeltaSummary with @debug.Debug::{to_repr}

///|
/// Detached domain-separated Ed25519 signature over a directory manifest JSON document.
#derive(Eq, Debug)
pub struct DirManifestSignature {
  priv key_id : String
  priv dir_manifest_sha256 : String
  priv signature_raw : Bytes
  priv signature_hex : String
}

///|
pub extend DirManifestSignature with Eq::{equal, not_equal}

///|
pub extend DirManifestSignature with @debug.Debug::{to_repr}

///|
/// Validate a strict POSIX relative path for directory delta entries.
pub fn validate_relative_path(path : String) -> Result[Unit, DirDeltaError] {
  let len = path.length()
  if len == 0 {
    return Err(InvalidPath(path~, detail="path must not be empty"))
  }
  if len > dir_max_path_length {
    return Err(
      InvalidPath(
        path~,
        detail="path exceeds maximum length of \{dir_max_path_length}",
      ),
    )
  }
  // Reject unpaired UTF-16 surrogates so UTF-8 encoding is lossless and canonical.
  let mut u = 0
  while u < len {
    let unit = path[u].to_int()
    if unit >= 0xD800 && unit <= 0xDBFF {
      if u + 1 >= len {
        return Err(
          InvalidPath(path~, detail="path contains unpaired UTF-16 surrogate"),
        )
      }
      let next = path[u + 1].to_int()
      if next < 0xDC00 || next > 0xDFFF {
        return Err(
          InvalidPath(path~, detail="path contains unpaired UTF-16 surrogate"),
        )
      }
      u = u + 2
    } else if unit >= 0xDC00 && unit <= 0xDFFF {
      return Err(
        InvalidPath(path~, detail="path contains unpaired UTF-16 surrogate"),
      )
    } else {
      u = u + 1
    }
  }
  for ch in path {
    let code = ch.to_int()
    if (code >= 0 && code <= 0x1F) || (code >= 0x7F && code <= 0x9F) {
      return Err(
        InvalidPath(
          path~,
          detail="path must not contain NUL or control characters",
        ),
      )
    }
  }
  let utf8 = @utf8.encode(path[:])
  let byte_len = utf8.length()
  if byte_len == 0 {
    return Err(InvalidPath(path~, detail="path must not be empty"))
  }
  if byte_len > dir_max_path_length {
    return Err(
      InvalidPath(
        path~,
        detail="path exceeds maximum UTF-8 byte length of \{dir_max_path_length}",
      ),
    )
  }
  if utf8[0] == b'/' {
    return Err(
      InvalidPath(path~, detail="path must be relative and not start with '/'"),
    )
  }
  if utf8[byte_len - 1] == b'/' {
    return Err(InvalidPath(path~, detail="path must not end with '/'"))
  }
  let mut seg_start = 0
  let mut seg_index = 0
  for i = 0; i < byte_len; i = i + 1 {
    let byte = utf8[i]
    let code = byte.to_int()
    if code < 0x20 || code == 0x7F {
      return Err(
        InvalidPath(
          path~,
          detail="path must not contain NUL or ASCII control characters",
        ),
      )
    }
    if byte == b'\\' {
      return Err(InvalidPath(path~, detail="path must not contain backslashes"))
    }
    if byte == b'/' {
      match dir_validate_path_segment(path, utf8, seg_start, i, seg_index) {
        Ok(_) => ()
        Err(err) => return Err(err)
      }
      seg_start = i + 1
      seg_index = seg_index + 1
    }
  }
  dir_validate_path_segment(path, utf8, seg_start, byte_len, seg_index)
}

///|
fn dir_validate_path_segment(
  path : String,
  utf8 : Bytes,
  start : Int32,
  end : Int32,
  seg_index : Int32,
) -> Result[Unit, DirDeltaError] {
  let seg_len = end - start
  if seg_len == 0 {
    return Err(
      InvalidPath(path~, detail="path must not contain empty segments"),
    )
  }
  if seg_len == 1 && utf8[start] == b'.' {
    return Err(InvalidPath(path~, detail="path must not contain '.' segments"))
  }
  if seg_len == 2 && utf8[start] == b'.' && utf8[start + 1] == b'.' {
    return Err(InvalidPath(path~, detail="path must not contain '..' segments"))
  }
  if seg_index == 0 {
    for i = start; i < end; i = i + 1 {
      if utf8[i] == b':' {
        return Err(
          InvalidPath(
            path~,
            detail="first path segment must not contain ':' (Windows drive prefix)",
          ),
        )
      }
    }
  }
  Ok(())
}

///|
fn dir_validate_blob_name(name : String) -> Result[Unit, DirDeltaError] {
  let len = name.length()
  if len == 0 {
    return Err(InvalidBlobName(name~, detail="blob_name must not be empty"))
  }
  if len > dir_max_blob_name_length {
    return Err(
      InvalidBlobName(
        name~,
        detail="blob_name exceeds maximum length of \{dir_max_blob_name_length}",
      ),
    )
  }
  let raw = @utf8.encode(name[:])
  if raw.length() == 0 || raw.length() > dir_max_blob_name_length {
    return Err(
      InvalidBlobName(name~, detail="blob_name length is out of bounds"),
    )
  }
  if raw[0] == b'.' {
    return Err(
      InvalidBlobName(name~, detail="blob_name must not start with '.'"),
    )
  }
  for i = 0; i < raw.length(); i = i + 1 {
    let code = raw[i].to_int()
    let allowed = (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      (code >= 48 && code <= 57) ||
      code == 46 ||
      code == 95 ||
      code == 45
    if !allowed {
      return Err(
        InvalidBlobName(name~, detail="blob_name must match [A-Za-z0-9._-]+"),
      )
    }
    if i > 0 && raw[i - 1] == b'.' && raw[i] == b'.' {
      return Err(
        InvalidBlobName(name~, detail="blob_name must not contain '..'"),
      )
    }
  }
  Ok(())
}

///|
fn dir_utf8_order_unit(unit : Int32) -> Int32 {
  if unit < 0xD800 {
    unit
  } else if unit >= 0xE000 {
    unit - 0x0800
  } else {
    unit + 0x2000
  }
}

///|
/// Compare two validated UTF-16 strings (no unpaired surrogates) in canonical
/// UTF-8 byte order without allocating temporary byte buffers.
fn dir_compare_utf8(a : String, b : String) -> Int32 {
  let len_a = a.length()
  let len_b = b.length()
  let min_len = if len_a < len_b { len_a } else { len_b }
  for i = 0; i < min_len; i = i + 1 {
    let ua = a[i].to_int()
    let ub = b[i].to_int()
    if ua != ub {
      return dir_utf8_order_unit(ua) - dir_utf8_order_unit(ub)
    }
  }
  len_a - len_b
}

///|
fn dir_slash_first_rank(unit : Int32) -> Int32 {
  if unit == 47 {
    0
  } else {
    unit + 1
  }
}

///|
/// Total order on validated paths where '/' sorts strictly before every other
/// code unit. Under this order, if any path `b` starts with `a + "/"`, the
/// immediately succeeding path after `a` must start with `a + "/"`.
fn dir_compare_slash_first(a : String, b : String) -> Int32 {
  let len_a = a.length()
  let len_b = b.length()
  let min_len = if len_a < len_b { len_a } else { len_b }
  for i = 0; i < min_len; i = i + 1 {
    let ua = a[i].to_int()
    let ub = b[i].to_int()
    if ua != ub {
      return dir_slash_first_rank(ua) - dir_slash_first_rank(ub)
    }
  }
  len_a - len_b
}

///|
fn dir_is_path_prefix(prefix : String, candidate : String) -> Bool {
  let plen = prefix.length()
  if candidate.length() <= plen || candidate[plen].to_int() != 47 {
    return false
  }
  for i = 0; i < plen; i = i + 1 {
    if prefix[i] != candidate[i] {
      return false
    }
  }
  true
}

///|
/// Check distinct validated paths for file-vs-directory prefix collisions
/// (e.g. "foo" and "foo/bar") with zero prefix-substring or map allocations:
/// sort in place under `dir_compare_slash_first` and scan adjacent pairs.
fn dir_check_prefix_collisions_in_place(
  paths : Array[String],
) -> Result[Unit, DirDeltaError] {
  if paths.length() <= 1 {
    return Ok(())
  }
  paths.sort_by(dir_compare_slash_first)
  for i = 1; i < paths.length(); i = i + 1 {
    let prev = paths[i - 1]
    let curr = paths[i]
    if dir_is_path_prefix(prev, curr) {
      return Err(PathCollision(a=prev, b=curr))
    }
  }
  Ok(())
}

///|
/// Validate a collection of paths for relative path safety, uniqueness,
/// and absence of file-vs-directory prefix collisions (e.g. "foo" and "foo/bar").
fn dir_validate_path_set(
  paths : Array[String],
) -> Result[Array[String], DirDeltaError] {
  for path in paths {
    match validate_relative_path(path) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  let sorted = paths.copy()
  sorted.sort_by(dir_compare_utf8)
  for i = 1; i < sorted.length(); i = i + 1 {
    if sorted[i - 1] == sorted[i] {
      return Err(DuplicatePath(sorted[i]))
    }
  }
  match dir_check_prefix_collisions_in_place(sorted.copy()) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok(sorted)
}

///|
priv struct DirSortedFile {
  path : String
  bytes : Bytes
  identity : ContentIdentity
}

///|
fn dir_validate_and_sort_entries(
  entries : Array[DirFileEntry],
) -> Result[Array[DirSortedFile], DirDeltaError] {
  for entry in entries {
    match validate_relative_path(entry.path) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  let copied = entries.copy()
  copied.sort_by((a, b) => dir_compare_utf8(a.path, b.path))
  let sorted_paths : Array[String] = []
  for i = 0; i < copied.length(); i = i + 1 {
    if i > 0 && copied[i - 1].path == copied[i].path {
      return Err(DuplicatePath(copied[i].path))
    }
    sorted_paths.push(copied[i].path)
  }
  match dir_check_prefix_collisions_in_place(sorted_paths) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let out : Array[DirSortedFile] = []
  for entry in copied {
    out.push({
      path: entry.path,
      bytes: entry.bytes,
      identity: ContentIdentity::of_bytes(entry.bytes),
    })
  }
  Ok(out)
}

///|
fn dir_tree_sha256_from_sorted_identities(
  items : Array[(String, ContentIdentity)],
) -> String {
  if items.length() == 0 {
    return @manifest_support.sha256_hex(b"")
  }
  let sb = StringBuilder(capacity=items.length() * 96)
  for item in items {
    let (path, identity) = item
    sb.write_string(identity.hash)
    sb.write_string(" ")
    sb.write_string("\{identity.size}")
    sb.write_string(" ")
    sb.write_string(path)
    sb.write_string("\n")
  }
  @manifest_support.sha256_hex(@utf8.encode(sb.to_string()[:]))
}

///|
/// Compute the canonical SHA-256 tree digest of an in-memory directory.
/// Validates all paths (rejecting invalid paths, duplicates, and prefix collisions),
/// sorts by canonical UTF-8 byte order of `path`, and hashes lines of
/// `"<sha256_hex> <size_bytes> <path>\n"` (empty directory hashes `b""`).
pub fn tree_sha256(
  entries : Array[DirFileEntry],
) -> Result[String, DirDeltaError] {
  let sorted = match dir_validate_and_sort_entries(entries) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let items : Array[(String, ContentIdentity)] = []
  for file in sorted {
    items.push((file.path, file.identity))
  }
  Ok(dir_tree_sha256_from_sorted_identities(items))
}

///|
fn dir_checked_add_i64(
  a : Int64,
  b : Int64,
  field : String,
) -> Result[Int64, DirDeltaError] {
  if b < 0L || b > dir_i64_max - a {
    Err(LimitExceeded(field~, value=dir_i64_max, limit=dir_i64_max))
  } else {
    Ok(a + b)
  }
}

///|
fn dir_format_blob_name(index : Int32, ext : String) -> String {
  let digits = "\{index}"
  let padded = if digits.length() == 1 {
    "000" + digits
  } else if digits.length() == 2 {
    "00" + digits
  } else if digits.length() == 3 {
    "0" + digits
  } else {
    digits
  }
  "blob-" + padded + "." + ext
}

///|
fn dir_identity_to_json(identity : ContentIdentity) -> @json.Json {
  @json.Json::object({
    "size_bytes": @json.Json::string("\{identity.size}"),
    "sha256": @json.Json::string(identity.hash),
  })
}

///|
fn dir_entry_action_to_json(action : DirEntryAction) -> @json.Json {
  match action {
    Unchanged(path~, identity~) =>
      @json.Json::object({
        "action": @json.Json::string("unchanged"),
        "path": @json.Json::string(path),
        "identity": dir_identity_to_json(identity),
      })
    Renamed(path~, from_path~, identity~) =>
      @json.Json::object({
        "action": @json.Json::string("renamed"),
        "path": @json.Json::string(path),
        "from_path": @json.Json::string(from_path),
        "identity": dir_identity_to_json(identity),
      })
    Patched(
      path~,
      from_path~,
      old_identity~,
      new_identity~,
      patch_identity~,
      blob_name~,
    ) =>
      @json.Json::object({
        "action": @json.Json::string("patched"),
        "path": @json.Json::string(path),
        "from_path": @json.Json::string(from_path),
        "old_identity": dir_identity_to_json(old_identity),
        "new_identity": dir_identity_to_json(new_identity),
        "patch_identity": dir_identity_to_json(patch_identity),
        "blob_name": @json.Json::string(blob_name),
      })
    Added(path~, identity~, blob_name~, full_fallback~) =>
      @json.Json::object({
        "action": @json.Json::string("added"),
        "path": @json.Json::string(path),
        "identity": dir_identity_to_json(identity),
        "blob_name": @json.Json::string(blob_name),
        "full_fallback": @json.Json::boolean(full_fallback),
      })
    Deleted(path~, old_identity~) =>
      @json.Json::object({
        "action": @json.Json::string("deleted"),
        "path": @json.Json::string(path),
        "old_identity": dir_identity_to_json(old_identity),
      })
  }
}

///|
/// Serialize a directory manifest to canonical schema 1 UTF-8 JSON bytes ending with `\n`.
pub fn DirManifest::to_json_bytes(self : DirManifest) -> Bytes {
  let json_entries : Array[@json.Json] = []
  for entry in self.entries {
    json_entries.push(dir_entry_action_to_json(entry))
  }
  let document = @json.Json::object({
    "schema": @json.Json::number(1.0),
    "type": @json.Json::string(dir_manifest_type),
    "old_tree_sha256": @json.Json::string(self.old_tree_sha256),
    "new_tree_sha256": @json.Json::string(self.new_tree_sha256),
    "old_file_count": @json.Json::number(self.old_file_count.to_double()),
    "new_file_count": @json.Json::number(self.new_file_count.to_double()),
    "old_total_bytes": @json.Json::string("\{self.old_total_bytes}"),
    "new_total_bytes": @json.Json::string("\{self.new_total_bytes}"),
    "delta_payload_bytes": @json.Json::string("\{self.delta_payload_bytes}"),
    "entries": @json.Json::array(json_entries),
  })
  @utf8.encode((document.stringify() + "\n")[:])
}

///|
fn dir_json_object(
  value : @json.Json,
  keys : Array[String],
  context : String,
) -> Map[String, @json.Json] raise DirDeltaFault {
  let fields = match value {
    @json.Object(fields) => fields
    _ =>
      raise DirRejected(
        InvalidSchema(
          field=context,
          detail="dir manifest: " + context + " must be an object",
        ),
      )
  }
  for key in keys {
    if fields.get(key) is None {
      let field = if context == "root" { key } else { context + "." + key }
      raise DirRejected(
        InvalidSchema(field~, detail="dir manifest: missing " + field),
      )
    }
  }
  for key, _ in fields {
    if !keys.contains(key) {
      let field = if context == "root" { key } else { context + "." + key }
      raise DirRejected(
        InvalidSchema(field~, detail="dir manifest: unknown field " + field),
      )
    }
  }
  fields
}

///|
fn dir_json_string(
  value : @json.Json,
  field : String,
) -> String raise DirDeltaFault {
  match value {
    @json.String(s) => s
    _ =>
      raise DirRejected(
        InvalidSchema(
          field~,
          detail="dir manifest: " + field + " must be a string",
        ),
      )
  }
}

///|
fn dir_json_bool(
  value : @json.Json,
  field : String,
) -> Bool raise DirDeltaFault {
  match value {
    @json.True => true
    @json.False => false
    _ =>
      raise DirRejected(
        InvalidSchema(
          field~,
          detail="dir manifest: " + field + " must be a boolean",
        ),
      )
  }
}

///|
fn dir_parse_decimal_i64_text(
  text : String,
  field : String,
) -> Int64 raise DirDeltaFault {
  let raw = @utf8.encode(text[:])
  if raw.length() == 0 {
    raise DirRejected(
      InvalidSchema(field~, detail="dir manifest: " + field + " is empty"),
    )
  }
  if raw.length() > 1 && raw[0] == b'0' {
    raise DirRejected(
      InvalidSchema(
        field~,
        detail="dir manifest: " + field + " must not have leading zeros",
      ),
    )
  }
  let mut acc = 0L
  for byte in raw {
    let digit = byte.to_int() - 48
    if digit < 0 || digit > 9 {
      raise DirRejected(
        InvalidSchema(
          field~,
          detail="dir manifest: " +
            field +
            " requires nonnegative ASCII decimal digits",
        ),
      )
    }
    if acc > (dir_i64_max - digit.to_int64()) / 10L {
      raise DirRejected(
        InvalidSchema(
          field~,
          detail="dir manifest: " + field + " overflows Int64",
        ),
      )
    }
    acc = acc * 10L + digit.to_int64()
  }
  acc
}

///|
fn dir_json_i64_string(
  value : @json.Json,
  field : String,
) -> Int64 raise DirDeltaFault {
  let text = dir_json_string(value, field)
  dir_parse_decimal_i64_text(text, field)
}

///|
fn dir_json_nonneg_i32(
  value : @json.Json,
  field : String,
) -> Int32 raise DirDeltaFault {
  let raw = match value {
    @json.Number(_, repr=Some(repr)) => repr
    _ =>
      raise DirRejected(
        InvalidSchema(
          field~,
          detail="dir manifest: " + field + " must be a nonnegative integer",
        ),
      )
  }
  let parsed = dir_parse_decimal_i64_text(raw, field)
  if parsed > dir_i32_max {
    raise DirRejected(
      InvalidSchema(
        field~,
        detail="dir manifest: " + field + " overflows Int32",
      ),
    )
  }
  parsed.to_int()
}

///|
fn dir_json_sha256_hex(
  value : @json.Json,
  field : String,
) -> String raise DirDeltaFault {
  let hash = dir_json_string(value, field)
  let encoded = @utf8.encode(hash[:])
  if encoded.length() != 64 {
    raise DirRejected(
      InvalidSchema(
        field~,
        detail="dir manifest: " + field + " requires 64 lowercase hex digits",
      ),
    )
  }
  for byte in encoded {
    let code = byte.to_int()
    if !((code >= 48 && code <= 57) || (code >= 97 && code <= 102)) {
      raise DirRejected(
        InvalidSchema(
          field~,
          detail="dir manifest: " + field + " requires lowercase hex digits",
        ),
      )
    }
  }
  hash
}

///|
fn dir_json_identity(
  value : @json.Json,
  context : String,
) -> ContentIdentity raise DirDeltaFault {
  let fields = dir_json_object(value, ["size_bytes", "sha256"], context)
  let size = dir_json_i64_string(fields["size_bytes"], context + ".size_bytes")
  let hash = dir_json_sha256_hex(fields["sha256"], context + ".sha256")
  { size, hash, }
}

///|
fn dir_json_validated_path(
  value : @json.Json,
  field : String,
) -> String raise DirDeltaFault {
  let path = dir_json_string(value, field)
  match validate_relative_path(path) {
    Ok(_) => path
    Err(err) => raise DirRejected(err)
  }
}

///|
fn dir_json_validated_blob_name(
  value : @json.Json,
  field : String,
) -> String raise DirDeltaFault {
  let name = dir_json_string(value, field)
  match dir_validate_blob_name(name) {
    Ok(_) => name
    Err(err) => raise DirRejected(err)
  }
}

///|
fn dir_json_entry_action(
  value : @json.Json,
  index : Int32,
) -> DirEntryAction raise DirDeltaFault {
  let context = "entries[\{index}]"
  let raw_fields = match value {
    @json.Object(fields) => fields
    _ =>
      raise DirRejected(
        InvalidSchema(
          field=context,
          detail="dir manifest: " + context + " must be an object",
        ),
      )
  }
  let action_val = match raw_fields.get("action") {
    Some(v) => v
    None =>
      raise DirRejected(
        InvalidSchema(
          field=context + ".action",
          detail="dir manifest: missing " + context + ".action",
        ),
      )
  }
  let action = dir_json_string(action_val, context + ".action")
  match action {
    "unchanged" => {
      let fields = dir_json_object(
        value,
        ["action", "path", "identity"],
        context,
      )
      let path = dir_json_validated_path(fields["path"], context + ".path")
      let identity = dir_json_identity(
        fields["identity"],
        context + ".identity",
      )
      Unchanged(path~, identity~)
    }
    "renamed" => {
      let fields = dir_json_object(
        value,
        ["action", "path", "from_path", "identity"],
        context,
      )
      let path = dir_json_validated_path(fields["path"], context + ".path")
      let from_path = dir_json_validated_path(
        fields["from_path"],
        context + ".from_path",
      )
      if path == from_path {
        raise DirRejected(
          InvalidSchema(
            field=context + ".from_path",
            detail="dir manifest: renamed entry must have path != from_path",
          ),
        )
      }
      let identity = dir_json_identity(
        fields["identity"],
        context + ".identity",
      )
      Renamed(path~, from_path~, identity~)
    }
    "patched" => {
      let fields = dir_json_object(
        value,
        [
          "action", "path", "from_path", "old_identity", "new_identity", "patch_identity",
          "blob_name",
        ],
        context,
      )
      let path = dir_json_validated_path(fields["path"], context + ".path")
      let from_path = dir_json_validated_path(
        fields["from_path"],
        context + ".from_path",
      )
      let old_identity = dir_json_identity(
        fields["old_identity"],
        context + ".old_identity",
      )
      let new_identity = dir_json_identity(
        fields["new_identity"],
        context + ".new_identity",
      )
      let patch_identity = dir_json_identity(
        fields["patch_identity"],
        context + ".patch_identity",
      )
      let blob_name = dir_json_validated_blob_name(
        fields["blob_name"],
        context + ".blob_name",
      )
      Patched(
        path~,
        from_path~,
        old_identity~,
        new_identity~,
        patch_identity~,
        blob_name~,
      )
    }
    "added" => {
      let fields = dir_json_object(
        value,
        ["action", "path", "identity", "blob_name", "full_fallback"],
        context,
      )
      let path = dir_json_validated_path(fields["path"], context + ".path")
      let identity = dir_json_identity(
        fields["identity"],
        context + ".identity",
      )
      let blob_name = dir_json_validated_blob_name(
        fields["blob_name"],
        context + ".blob_name",
      )
      let full_fallback = dir_json_bool(
        fields["full_fallback"],
        context + ".full_fallback",
      )
      Added(path~, identity~, blob_name~, full_fallback~)
    }
    "deleted" => {
      let fields = dir_json_object(
        value,
        ["action", "path", "old_identity"],
        context,
      )
      let path = dir_json_validated_path(fields["path"], context + ".path")
      let old_identity = dir_json_identity(
        fields["old_identity"],
        context + ".old_identity",
      )
      Deleted(path~, old_identity~)
    }
    _ =>
      raise DirRejected(
        InvalidSchema(
          field=context + ".action",
          detail="dir manifest: unsupported action " + action,
        ),
      )
  }
}

///|
fn dir_parse_manifest_inner(data : Bytes) -> DirManifest raise DirDeltaFault {
  let size = data.length().to_int64()
  let max_bytes = max_dir_manifest_bytes.to_int64()
  if size > max_bytes {
    raise DirRejected(
      LimitExceeded(field="max_dir_manifest_bytes", value=size, limit=max_bytes),
    )
  }
  if data is [0xef, 0xbb, 0xbf, ..] {
    raise DirRejected(InvalidEncoding)
  }
  let text = @utf8.decode(data[:], ignore_bom=false) catch {
    _ => raise DirRejected(InvalidEncoding)
  }
  if json_exceeds_max_depth(text[:], 16) {
    raise DirRejected(
      InvalidJson(field=None, detail="nesting depth limit exceeded"),
    )
  }
  let json = @json.parse(
    text[:],
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => {
      let field = json_duplicate_key_field(error)
      raise DirRejected(InvalidJson(field~, detail=@debug.to_string(error)))
    }
  }
  let fields = dir_json_object(
    json,
    [
      "schema", "type", "old_tree_sha256", "new_tree_sha256", "old_file_count", "new_file_count",
      "old_total_bytes", "new_total_bytes", "delta_payload_bytes", "entries",
    ],
    "root",
  )
  if !(fields["schema"] is @json.Number(_, repr=Some("1"))) {
    raise DirRejected(
      InvalidSchema(
        field="schema",
        detail="dir manifest: expected schema integer 1",
      ),
    )
  }
  if dir_json_string(fields["type"], "type") != dir_manifest_type {
    raise DirRejected(
      InvalidSchema(
        field="type",
        detail="dir manifest: expected type " + dir_manifest_type,
      ),
    )
  }
  let old_tree_sha256 = dir_json_sha256_hex(
    fields["old_tree_sha256"],
    "old_tree_sha256",
  )
  let new_tree_sha256 = dir_json_sha256_hex(
    fields["new_tree_sha256"],
    "new_tree_sha256",
  )
  let old_file_count = dir_json_nonneg_i32(
    fields["old_file_count"],
    "old_file_count",
  )
  let new_file_count = dir_json_nonneg_i32(
    fields["new_file_count"],
    "new_file_count",
  )
  let old_total_bytes = dir_json_i64_string(
    fields["old_total_bytes"],
    "old_total_bytes",
  )
  let new_total_bytes = dir_json_i64_string(
    fields["new_total_bytes"],
    "new_total_bytes",
  )
  let delta_payload_bytes = dir_json_i64_string(
    fields["delta_payload_bytes"],
    "delta_payload_bytes",
  )
  let raw_entries = match fields["entries"] {
    @json.Array(items) => items
    _ =>
      raise DirRejected(
        InvalidSchema(
          field="entries",
          detail="dir manifest: entries must be an array",
        ),
      )
  }
  let parsed_entries : Array[DirEntryAction] = []
  let new_paths : Array[String] = []
  let new_identities : Array[(String, ContentIdentity)] = []
  let deleted_paths : Array[String] = []
  let old_asserted : Map[String, ContentIdentity] = Map([])
  let seen_blobs : Map[String, Unit] = Map([])
  let patched_from_paths : Map[String, Unit] = Map([])
  let mut computed_new_bytes = 0L
  let mut computed_delta_bytes = 0L
  let record_old_assertion = (path : String, identity : ContentIdentity) => {
    match old_asserted.get(path) {
      Some(existing) =>
        if existing != identity {
          raise DirRejected(
            InvalidSchema(
              field="entries",
              detail="dir manifest: conflicting old_identity for path " + path,
            ),
          )
        }
      None => old_asserted[path] = identity
    }
  }
  for idx, item in raw_entries {
    let entry = dir_json_entry_action(item, idx)
    match entry {
      Unchanged(path~, identity~) => {
        new_paths.push(path)
        new_identities.push((path, identity))
        record_old_assertion(path, identity)
        computed_new_bytes = match
          dir_checked_add_i64(
            computed_new_bytes,
            identity.size,
            "new_total_bytes",
          ) {
          Ok(v) => v
          Err(err) => raise DirRejected(err)
        }
      }
      Renamed(path~, from_path~, identity~) => {
        new_paths.push(path)
        new_identities.push((path, identity))
        record_old_assertion(from_path, identity)
        computed_new_bytes = match
          dir_checked_add_i64(
            computed_new_bytes,
            identity.size,
            "new_total_bytes",
          ) {
          Ok(v) => v
          Err(err) => raise DirRejected(err)
        }
      }
      Patched(
        path~,
        from_path~,
        old_identity~,
        new_identity~,
        patch_identity~,
        blob_name~,
      ) => {
        if seen_blobs.contains(blob_name) {
          raise DirRejected(DuplicateBlob(blob_name))
        }
        seen_blobs[blob_name] = ()
        if patched_from_paths.contains(from_path) {
          raise DirRejected(
            InvalidSchema(
              field="entries",
              detail="dir manifest: duplicate patched from_path: " + from_path,
            ),
          )
        }
        patched_from_paths[from_path] = ()
        new_paths.push(path)
        new_identities.push((path, new_identity))
        record_old_assertion(from_path, old_identity)
        computed_new_bytes = match
          dir_checked_add_i64(
            computed_new_bytes,
            new_identity.size,
            "new_total_bytes",
          ) {
          Ok(v) => v
          Err(err) => raise DirRejected(err)
        }
        computed_delta_bytes = match
          dir_checked_add_i64(
            computed_delta_bytes,
            patch_identity.size,
            "delta_payload_bytes",
          ) {
          Ok(v) => v
          Err(err) => raise DirRejected(err)
        }
      }
      Added(path~, identity~, blob_name~, full_fallback=_) => {
        if seen_blobs.contains(blob_name) {
          raise DirRejected(DuplicateBlob(blob_name))
        }
        seen_blobs[blob_name] = ()
        new_paths.push(path)
        new_identities.push((path, identity))
        computed_new_bytes = match
          dir_checked_add_i64(
            computed_new_bytes,
            identity.size,
            "new_total_bytes",
          ) {
          Ok(v) => v
          Err(err) => raise DirRejected(err)
        }
        computed_delta_bytes = match
          dir_checked_add_i64(
            computed_delta_bytes,
            identity.size,
            "delta_payload_bytes",
          ) {
          Ok(v) => v
          Err(err) => raise DirRejected(err)
        }
      }
      Deleted(path~, old_identity~) => {
        deleted_paths.push(path)
        record_old_assertion(path, old_identity)
      }
    }
    parsed_entries.push(entry)
  }
  // Validate new-tree path uniqueness & prefix collisions.
  let validated_new_paths = match dir_validate_path_set(new_paths) {
    Ok(v) => v
    Err(err) => raise DirRejected(err)
  }
  // Validate deleted path uniqueness & disjointness from new-tree paths.
  let new_path_set : Map[String, Unit] = Map([])
  for p in validated_new_paths {
    new_path_set[p] = ()
  }
  let seen_deleted : Map[String, Unit] = Map([])
  for p in deleted_paths {
    if seen_deleted.contains(p) {
      raise DirRejected(DuplicatePath(p))
    }
    if new_path_set.contains(p) {
      raise DirRejected(
        InvalidSchema(
          field="entries",
          detail="dir manifest: path cannot be both present in new tree and deleted: " +
            p,
        ),
      )
    }
    seen_deleted[p] = ()
  }
  // Validate old-tree asserted paths have no file-vs-directory prefix collisions.
  let old_asserted_paths : Array[String] = []
  let mut computed_old_asserted_bytes = 0L
  for p, id in old_asserted {
    old_asserted_paths.push(p)
    computed_old_asserted_bytes = match
      dir_checked_add_i64(
        computed_old_asserted_bytes,
        id.size,
        "old_total_bytes",
      ) {
      Ok(v) => v
      Err(err) => raise DirRejected(err)
    }
  }
  match dir_validate_path_set(old_asserted_paths) {
    Ok(_) => ()
    Err(err) => raise DirRejected(err)
  }
  // Cross-check declared counts, totals, and new_tree_sha256 against entries.
  if validated_new_paths.length() != new_file_count {
    raise DirRejected(
      InvalidSchema(
        field="new_file_count",
        detail="dir manifest: new_file_count does not match entries",
      ),
    )
  }
  if computed_new_bytes != new_total_bytes {
    raise DirRejected(
      InvalidSchema(
        field="new_total_bytes",
        detail="dir manifest: new_total_bytes does not match entries",
      ),
    )
  }
  if computed_delta_bytes != delta_payload_bytes {
    raise DirRejected(
      InvalidSchema(
        field="delta_payload_bytes",
        detail="dir manifest: delta_payload_bytes does not match entries",
      ),
    )
  }
  if old_file_count < deleted_paths.length() ||
    old_file_count < old_asserted_paths.length() {
    raise DirRejected(
      InvalidSchema(
        field="old_file_count",
        detail="dir manifest: old_file_count is smaller than referenced old paths",
      ),
    )
  }
  if old_file_count.to_int64() >
    new_file_count.to_int64() + deleted_paths.length().to_int64() {
    raise DirRejected(
      InvalidSchema(
        field="old_file_count",
        detail="dir manifest: old_file_count exceeds new_file_count + deleted entries",
      ),
    )
  }
  if computed_old_asserted_bytes > old_total_bytes ||
    (
      old_asserted_paths.length() == old_file_count &&
      computed_old_asserted_bytes != old_total_bytes
    ) {
    raise DirRejected(
      InvalidSchema(
        field="old_total_bytes",
        detail="dir manifest: old_total_bytes is inconsistent with referenced old files",
      ),
    )
  }
  if old_file_count == 0 {
    if old_total_bytes != 0L {
      raise DirRejected(
        InvalidSchema(
          field="old_total_bytes",
          detail="dir manifest: old_total_bytes must be 0 when old_file_count is 0",
        ),
      )
    }
    if old_tree_sha256 != @manifest_support.sha256_hex(b"") {
      raise DirRejected(
        InvalidSchema(
          field="old_tree_sha256",
          detail="dir manifest: old_tree_sha256 must be empty-tree digest when old_file_count is 0",
        ),
      )
    }
  }
  new_identities.sort_by((a, b) => dir_compare_utf8(a.0, b.0))
  let computed_new_tree = dir_tree_sha256_from_sorted_identities(new_identities)
  if computed_new_tree != new_tree_sha256 {
    raise DirRejected(
      InvalidSchema(
        field="new_tree_sha256",
        detail="dir manifest: new_tree_sha256 does not match declared entries",
      ),
    )
  }
  {
    old_tree_sha256,
    new_tree_sha256,
    old_file_count,
    new_file_count,
    old_total_bytes,
    new_total_bytes,
    delta_payload_bytes,
    entries: ReadOnlyArray::makei(parsed_entries.length(), i => {
      parsed_entries[i]
    }),
  }
}

///|
/// Parse and strictly validate a schema 1 directory manifest JSON document.
pub fn DirManifest::from_json_bytes(
  data : Bytes,
) -> Result[DirManifest, DirDeltaError] {
  Ok(dir_parse_manifest_inner(data)) catch {
    DirRejected(err) => Err(err)
  }
}

///|
fn dir_check_manifest_size_limit_sig(
  manifest_bytes : Bytes,
) -> Result[Unit, SignatureError] {
  let size = manifest_bytes.length().to_int64()
  let limit = max_dir_manifest_bytes.to_int64()
  if size > limit {
    return Err(
      LimitExceeded(field="max_dir_manifest_bytes", value=size, limit~),
    )
  }
  Ok(())
}

///|
fn dir_parse_signature_envelope(
  data : Bytes,
) -> Result[Map[String, @json.Json], SignatureError] {
  let size = data.length().to_int64()
  let max_bytes = max_signature_file_bytes.to_int64()
  if size > max_bytes {
    return Err(
      LimitExceeded(
        field="max_signature_file_bytes",
        value=size,
        limit=max_bytes,
      ),
    )
  }
  if data is [0xef, 0xbb, 0xbf, ..] {
    return Err(InvalidEncoding)
  }
  let text = @utf8.decode(data[:], ignore_bom=false) catch {
    _ => return Err(InvalidEncoding)
  }
  if json_exceeds_max_depth(text[:], 4) {
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
  let fields = match json {
    @json.Object(fields) => fields
    _ =>
      return Err(
        InvalidSchema(
          field="root",
          detail="dir signature envelope: root must be an object",
        ),
      )
  }
  let required_keys = [
    "schema", "type", "algorithm", "key_id", "dir_manifest_sha256", "signature",
  ]
  for key in required_keys {
    if fields.get(key) is None {
      return Err(
        InvalidSchema(
          field=key,
          detail="dir signature envelope: missing " + key,
        ),
      )
    }
  }
  for key, _ in fields {
    if !required_keys.contains(key) {
      return Err(
        InvalidSchema(
          field=key,
          detail="dir signature envelope: unknown field " + key,
        ),
      )
    }
  }
  if !(fields["schema"] is @json.Number(_, repr=Some("1"))) {
    return Err(
      InvalidSchema(
        field="schema",
        detail="dir signature envelope: expected integer 1",
      ),
    )
  }
  let envelope_type = match envelope_string(fields["type"], "type") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if envelope_type != dir_signature_type {
    return Err(
      InvalidSchema(
        field="type",
        detail="dir signature envelope: expected type " + dir_signature_type,
      ),
    )
  }
  let algorithm = match envelope_string(fields["algorithm"], "algorithm") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if algorithm != "ed25519" {
    return Err(
      InvalidSchema(
        field="algorithm",
        detail="dir signature envelope: only ed25519 is supported",
      ),
    )
  }
  Ok(fields)
}

///|
/// Parse a strict schema-1 detached directory manifest signature JSON envelope.
pub fn DirManifestSignature::from_json_bytes(
  data : Bytes,
) -> Result[DirManifestSignature, SignatureError] {
  let fields = match dir_parse_signature_envelope(data) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (key_id, _) = match parse_lowercase_hex(fields["key_id"], "key_id", 16) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (dir_manifest_sha256, _) = match
    parse_lowercase_hex(
      fields["dir_manifest_sha256"],
      "dir_manifest_sha256",
      64,
    ) {
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
  Ok({ key_id, dir_manifest_sha256, signature_raw, signature_hex, })
}

///|
/// Serialize a detached directory manifest signature to canonical JSON bytes.
pub fn DirManifestSignature::to_json_bytes(
  self : DirManifestSignature,
) -> Bytes {
  encode_envelope_json({
    "schema": @json.Json::number(1.0),
    "type": @json.Json::string(dir_signature_type),
    "algorithm": @json.Json::string("ed25519"),
    "key_id": @json.Json::string(self.key_id),
    "dir_manifest_sha256": @json.Json::string(self.dir_manifest_sha256),
    "signature": @json.Json::string(self.signature_hex),
  })
}

///|
pub fn DirManifestSignature::key_id(self : DirManifestSignature) -> String {
  self.key_id
}

///|
pub fn DirManifestSignature::dir_manifest_sha256(
  self : DirManifestSignature,
) -> String {
  self.dir_manifest_sha256
}

///|
pub fn DirManifestSignature::signature_bytes(
  self : DirManifestSignature,
) -> Bytes {
  self.signature_raw
}

///|
pub fn DirManifestSignature::signature_hex(
  self : DirManifestSignature,
) -> String {
  self.signature_hex
}

///|
/// Validate `manifest_bytes` as a strict schema 1 directory manifest, then sign
/// the exact bytes with domain-separated Ed25519 (`DIR_MANIFEST_SIGNATURE_DOMAIN`).
pub fn PrivateKey::sign_dir_manifest(
  self : PrivateKey,
  manifest_bytes : Bytes,
) -> Result[DirManifestSignature, DirDeltaError] {
  match DirManifest::from_json_bytes(manifest_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let payload = DIR_MANIFEST_SIGNATURE_DOMAIN + manifest_bytes
  let sig_raw = @spec.Signer::sign(self.inner, payload[:])
  match validate_raw_signature_format(sig_raw[:]) {
    Ok(_) => ()
    Err(err) => return Err(Signature(err))
  }
  Ok({
    key_id: self.pub_key.key_id,
    dir_manifest_sha256: @manifest_support.sha256_hex(manifest_bytes),
    signature_raw: sig_raw,
    signature_hex: @manifest_support.digest_hex(sig_raw),
  })
}

///|
/// Verify a detached `DirManifestSignature` over `manifest_bytes` against `public_key`
/// using `DIR_MANIFEST_SIGNATURE_DOMAIN` before any manifest parsing.
pub fn verify_dir_manifest_signature(
  manifest_bytes : Bytes,
  sig : DirManifestSignature,
  public_key : PublicKey,
) -> Result[Unit, SignatureError] {
  match dir_check_manifest_size_limit_sig(manifest_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if sig.key_id != public_key.key_id {
    return Err(KeyIdMismatch(expected=public_key.key_id, actual=sig.key_id))
  }
  let actual_hash = @manifest_support.sha256_hex(manifest_bytes)
  if actual_hash != sig.dir_manifest_sha256 {
    return Err(
      ManifestHashMismatch(expected=sig.dir_manifest_sha256, actual=actual_hash),
    )
  }
  match validate_raw_signature_format(sig.signature_raw[:]) {
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
  let payload = DIR_MANIFEST_SIGNATURE_DOMAIN + manifest_bytes
  if @spec.Verifier::verify(ed_pk, payload[:], sig.signature_raw[:]) {
    Ok(())
  } else {
    Err(VerificationFailed)
  }
}

///|
/// Verify a detached `DirManifestSignature` against a set of trusted public keys
/// (supporting key rotation, deduplication, and conflicting-key_id rejection)
/// and return the matching trusted `PublicKey`.
pub fn verify_dir_manifest_signature_with_keys(
  manifest_bytes : Bytes,
  sig : DirManifestSignature,
  keys : Array[PublicKey],
) -> Result[PublicKey, SignatureError] {
  match dir_check_manifest_size_limit_sig(manifest_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if keys.length() == 0 {
    return Err(InvalidPublicKey(detail="trusted key list must not be empty"))
  }
  let store = match TrustStore::from_keys(keys) {
    Ok(s) => s
    Err(err) => return Err(err)
  }
  let public_key = match store.find(sig.key_id) {
    Some(pk) => pk
    None =>
      return Err(
        KeyIdMismatch(
          expected=catalog_join_key_ids(store.key_ids()),
          actual=sig.key_id,
        ),
      )
  }
  match verify_dir_manifest_signature(manifest_bytes, sig, public_key) {
    Ok(_) => Ok(public_key)
    Err(err) => Err(err)
  }
}

///|
/// Compute a deterministic summary of a parsed directory manifest.
pub fn dir_summarize(manifest : DirManifest) -> DirDeltaSummary {
  let mut unchanged_count = 0
  let mut renamed_count = 0
  let mut patched_count = 0
  let mut added_count = 0
  let mut full_fallback_count = 0
  let mut deleted_count = 0
  for entry in manifest.entries {
    match entry {
      Unchanged(..) => unchanged_count = unchanged_count + 1
      Renamed(..) => renamed_count = renamed_count + 1
      Patched(..) => patched_count = patched_count + 1
      Added(full_fallback~, ..) => {
        added_count = added_count + 1
        if full_fallback {
          full_fallback_count = full_fallback_count + 1
        }
      }
      Deleted(..) => deleted_count = deleted_count + 1
    }
  }
  {
    unchanged_count,
    renamed_count,
    patched_count,
    added_count,
    full_fallback_count,
    deleted_count,
    old_total_bytes: manifest.old_total_bytes,
    new_total_bytes: manifest.new_total_bytes,
    delta_payload_bytes: manifest.delta_payload_bytes,
    old_tree_sha256: manifest.old_tree_sha256,
    new_tree_sha256: manifest.new_tree_sha256,
  }
}

///|
/// Diff two in-memory directory trees into a deterministic schema 1 directory delta bundle.
pub fn dir_diff(
  old_entries : Array[DirFileEntry],
  new_entries : Array[DirFileEntry],
  limits : @moonbsdiff.Limits,
) -> Result[DirDeltaBundle, DirDeltaError] {
  match limits.validate() {
    Ok(_) => ()
    Err(err) => return Err(InvalidLimits(err))
  }
  let old_sorted = match dir_validate_and_sort_entries(old_entries) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let new_sorted = match dir_validate_and_sort_entries(new_entries) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let old_id_items : Array[(String, ContentIdentity)] = []
  let old_by_path : Map[String, DirSortedFile] = Map([])
  let old_by_identity : Map[(Int64, String), Array[String]] = Map([])
  let mut old_total_bytes = 0L
  for file in old_sorted {
    old_id_items.push((file.path, file.identity))
    old_by_path[file.path] = file
    old_by_identity
    .get_or_init((file.identity.size, file.identity.hash), () => [])
    .push(file.path)
    old_total_bytes = match
      dir_checked_add_i64(
        old_total_bytes,
        file.identity.size,
        "old_total_bytes",
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
  }
  let new_id_items : Array[(String, ContentIdentity)] = []
  let new_path_set : Map[String, Unit] = Map([])
  let mut new_total_bytes = 0L
  for file in new_sorted {
    new_id_items.push((file.path, file.identity))
    new_path_set[file.path] = ()
    new_total_bytes = match
      dir_checked_add_i64(
        new_total_bytes,
        file.identity.size,
        "new_total_bytes",
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
  }
  let old_tree_sha256 = dir_tree_sha256_from_sorted_identities(old_id_items)
  let new_tree_sha256 = dir_tree_sha256_from_sorted_identities(new_id_items)
  let actions : Array[DirEntryAction] = []
  let blobs : Array[DirBlob] = []
  let mut blob_seq = 0
  let mut delta_payload_bytes = 0L
  let used_old_paths : Map[String, Unit] = Map([])
  for new_file in new_sorted {
    match old_by_path.get(new_file.path) {
      Some(old_same) if old_same.identity == new_file.identity =>
        used_old_paths[new_file.path] = ()
      _ => ()
    }
  }
  let mut cloned_bytes = 0L
  for new_file in new_sorted {
    let new_size = new_file.identity.size
    match old_by_path.get(new_file.path) {
      Some(old_same) if old_same.identity == new_file.identity => {
        match dir_check_limit("max_old_bytes", new_size, limits.max_old_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match dir_check_limit("max_new_bytes", new_size, limits.max_new_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit("max_output_bytes", new_size, limits.max_output_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        actions.push(Unchanged(path=new_file.path, identity=new_file.identity))
      }
      _ => {
        let mut rename_source = match
          old_by_identity.get((new_file.identity.size, new_file.identity.hash)) {
          Some(candidates) if candidates.length() > 0 => {
            let mut chosen : String? = None
            for cand in candidates {
              if !new_path_set.contains(cand) && !used_old_paths.contains(cand) {
                chosen = Some(cand)
                break
              }
            }
            if chosen is None {
              for cand in candidates {
                if !used_old_paths.contains(cand) {
                  chosen = Some(cand)
                  break
                }
              }
            }
            if chosen is None {
              for cand in candidates {
                if !new_path_set.contains(cand) {
                  chosen = Some(cand)
                  break
                }
              }
            }
            match chosen {
              Some(p) => Some(p)
              None => Some(candidates[0])
            }
          }
          _ => None
        }
        match rename_source {
          Some(from_path) => {
            match
              dir_check_limit("max_old_bytes", new_size, limits.max_old_bytes) {
              Ok(_) => ()
              Err(err) => return Err(err)
            }
            match
              dir_check_limit("max_new_bytes", new_size, limits.max_new_bytes) {
              Ok(_) => ()
              Err(err) => return Err(err)
            }
            match
              dir_check_limit(
                "max_output_bytes",
                new_size,
                limits.max_output_bytes,
              ) {
              Ok(_) => ()
              Err(err) => return Err(err)
            }
            if !used_old_paths.contains(from_path) {
              used_old_paths[from_path] = ()
            } else {
              match
                dir_checked_add_i64(cloned_bytes, new_size, "max_output_bytes") {
                Ok(next_cloned) if next_cloned <= limits.max_output_bytes =>
                  cloned_bytes = next_cloned
                _ => rename_source = None
              }
            }
          }
          None => ()
        }
        match rename_source {
          Some(from_path) =>
            actions.push(
              Renamed(
                path=new_file.path,
                from_path~,
                identity=new_file.identity,
              ),
            )
          None => {
            if new_size > limits.max_new_bytes {
              return Err(
                LimitExceeded(
                  field="max_new_bytes",
                  value=new_size,
                  limit=limits.max_new_bytes,
                ),
              )
            }
            if new_size > limits.max_output_bytes {
              return Err(
                LimitExceeded(
                  field="max_output_bytes",
                  value=new_size,
                  limit=limits.max_output_bytes,
                ),
              )
            }
            match old_by_path.get(new_file.path) {
              Some(old_same) => {
                let already_used = used_old_paths.contains(old_same.path)
                let next_cloned_if_patched : Int64? = if !already_used {
                  Some(cloned_bytes)
                } else {
                  match
                    dir_checked_add_i64(
                      cloned_bytes, new_size, "max_output_bytes",
                    ) {
                    Ok(next_cloned) if next_cloned <= limits.max_output_bytes =>
                      Some(next_cloned)
                    _ => None
                  }
                }
                let patch_opt : Bytes? = match next_cloned_if_patched {
                  Some(_) =>
                    match
                      @moonbsdiff.diff(old_same.bytes, new_file.bytes, limits) {
                      Ok(patch) if patch.length() < new_file.bytes.length() =>
                        Some(patch)
                      _ => None
                    }
                  None => None
                }
                match (patch_opt, next_cloned_if_patched) {
                  (Some(patch), Some(next_cloned)) => {
                    if !already_used {
                      used_old_paths[old_same.path] = ()
                    } else {
                      cloned_bytes = next_cloned
                    }
                    blob_seq = blob_seq + 1
                    let blob_name = dir_format_blob_name(blob_seq, "patch")
                    let patch_identity = ContentIdentity::of_bytes(patch)
                    delta_payload_bytes = match
                      dir_checked_add_i64(
                        delta_payload_bytes,
                        patch_identity.size,
                        "delta_payload_bytes",
                      ) {
                      Ok(v) => v
                      Err(err) => return Err(err)
                    }
                    blobs.push({ name: blob_name, bytes: patch, })
                    actions.push(
                      Patched(
                        path=new_file.path,
                        from_path=old_same.path,
                        old_identity=old_same.identity,
                        new_identity=new_file.identity,
                        patch_identity~,
                        blob_name~,
                      ),
                    )
                  }
                  _ => {
                    blob_seq = blob_seq + 1
                    let blob_name = dir_format_blob_name(blob_seq, "full")
                    delta_payload_bytes = match
                      dir_checked_add_i64(
                        delta_payload_bytes, new_size, "delta_payload_bytes",
                      ) {
                      Ok(v) => v
                      Err(err) => return Err(err)
                    }
                    blobs.push({ name: blob_name, bytes: new_file.bytes, })
                    actions.push(
                      Added(
                        path=new_file.path,
                        identity=new_file.identity,
                        blob_name~,
                        full_fallback=true,
                      ),
                    )
                  }
                }
              }
              None => {
                blob_seq = blob_seq + 1
                let blob_name = dir_format_blob_name(blob_seq, "full")
                delta_payload_bytes = match
                  dir_checked_add_i64(
                    delta_payload_bytes, new_size, "delta_payload_bytes",
                  ) {
                  Ok(v) => v
                  Err(err) => return Err(err)
                }
                blobs.push({ name: blob_name, bytes: new_file.bytes, })
                actions.push(
                  Added(
                    path=new_file.path,
                    identity=new_file.identity,
                    blob_name~,
                    full_fallback=false,
                  ),
                )
              }
            }
          }
        }
      }
    }
  }
  for old_file in old_sorted {
    if !new_path_set.contains(old_file.path) {
      actions.push(Deleted(path=old_file.path, old_identity=old_file.identity))
    }
  }
  let manifest : DirManifest = {
    old_tree_sha256,
    new_tree_sha256,
    old_file_count: old_sorted.length(),
    new_file_count: new_sorted.length(),
    old_total_bytes,
    new_total_bytes,
    delta_payload_bytes,
    entries: ReadOnlyArray::makei(actions.length(), i => actions[i]),
  }
  let manifest_bytes = manifest.to_json_bytes()
  if manifest_bytes.length() > max_dir_manifest_bytes {
    return Err(
      LimitExceeded(
        field="max_dir_manifest_bytes",
        value=manifest_bytes.length().to_int64(),
        limit=max_dir_manifest_bytes.to_int64(),
      ),
    )
  }
  Ok({
    manifest,
    manifest_bytes,
    blobs: ReadOnlyArray::makei(blobs.length(), i => blobs[i]),
  })
}

///|
fn dir_verify_content_identity(
  path : String,
  object : ContentObject,
  actual_bytes : Bytes,
  expected : ContentIdentity,
) -> Result[Unit, DirDeltaError] {
  let actual_size = actual_bytes.length().to_int64()
  if actual_size != expected.size {
    return Err(
      IdentityMismatch(
        path~,
        object~,
        difference=Size(expected=expected.size, actual=actual_size),
      ),
    )
  }
  if @manifest_support.sha256_hex(actual_bytes) != expected.hash {
    return Err(IdentityMismatch(path~, object~, difference=Sha256))
  }
  Ok(())
}

///|
fn dir_verify_precomputed_identity(
  path : String,
  object : ContentObject,
  actual : ContentIdentity,
  expected : ContentIdentity,
) -> Result[Unit, DirDeltaError] {
  if actual.size != expected.size {
    return Err(
      IdentityMismatch(
        path~,
        object~,
        difference=Size(expected=expected.size, actual=actual.size),
      ),
    )
  }
  if actual.hash != expected.hash {
    return Err(IdentityMismatch(path~, object~, difference=Sha256))
  }
  Ok(())
}

///|
fn dir_check_limit(
  field : String,
  value : Int64,
  limit : Int64,
) -> Result[Unit, DirDeltaError] {
  if value > limit {
    Err(LimitExceeded(field~, value~, limit~))
  } else {
    Ok(())
  }
}

///|
/// Apply a schema 1 directory delta manifest and its payload blobs to `old_entries`.
/// Verifies `old_tree_sha256` before applying, rejects duplicate/unsafe/missing/extra blobs,
/// checks every file and patch identity, and verifies final `new_tree_sha256`, file count, and total bytes.
pub fn dir_apply(
  old_entries : Array[DirFileEntry],
  manifest_bytes : Bytes,
  blobs : Array[DirBlob],
  limits : @moonbsdiff.Limits,
) -> Result[(Array[DirFileEntry], DirDeltaSummary), DirDeltaError] {
  match limits.validate() {
    Ok(_) => ()
    Err(err) => return Err(InvalidLimits(err))
  }
  let old_sorted = match dir_validate_and_sort_entries(old_entries) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let manifest = match DirManifest::from_json_bytes(manifest_bytes) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let old_id_items : Array[(String, ContentIdentity)] = []
  let old_by_path : Map[String, DirSortedFile] = Map([])
  let mut actual_old_bytes = 0L
  for file in old_sorted {
    old_id_items.push((file.path, file.identity))
    old_by_path[file.path] = file
    actual_old_bytes = match
      dir_checked_add_i64(
        actual_old_bytes,
        file.identity.size,
        "old_total_bytes",
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
  }
  let actual_old_tree = dir_tree_sha256_from_sorted_identities(old_id_items)
  if actual_old_tree != manifest.old_tree_sha256 {
    return Err(
      OldTreeMismatch(expected=manifest.old_tree_sha256, actual=actual_old_tree),
    )
  }
  if old_sorted.length() != manifest.old_file_count {
    return Err(
      InvalidSchema(
        field="old_file_count",
        detail="dir apply: old_file_count does not match old_entries",
      ),
    )
  }
  if actual_old_bytes != manifest.old_total_bytes {
    return Err(
      InvalidSchema(
        field="old_total_bytes",
        detail="dir apply: old_total_bytes does not match old_entries",
      ),
    )
  }
  // Validate blobs for unsafe names, duplicates, missing references, and unreferenced extras.
  let blob_map : Map[String, Bytes] = Map([])
  for blob in blobs {
    match dir_validate_blob_name(blob.name) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    if blob_map.contains(blob.name) {
      return Err(DuplicateBlob(blob.name))
    }
    blob_map[blob.name] = blob.bytes
  }
  let referenced_blobs : Map[String, Unit] = Map([])
  for entry in manifest.entries {
    match entry {
      Patched(blob_name~, ..) | Added(blob_name~, ..) => {
        if !blob_map.contains(blob_name) {
          return Err(MissingBlob(blob_name))
        }
        referenced_blobs[blob_name] = ()
      }
      _ => ()
    }
  }
  for blob in blobs {
    if !referenced_blobs.contains(blob.name) {
      return Err(UnexpectedBlob(blob.name))
    }
  }
  // Apply each action with strict identity, per-file limit, and clone-amplification checks.
  let used_old_paths : Map[String, Unit] = Map([])
  for entry in manifest.entries {
    if entry is Unchanged(path~, ..) {
      used_old_paths[path] = ()
    }
  }
  let mut cloned_bytes = 0L
  let restored_files : Array[DirSortedFile] = []
  let restored_paths : Map[String, Unit] = Map([])
  let deleted_paths : Map[String, Unit] = Map([])
  for entry in manifest.entries {
    match entry {
      Unchanged(path~, identity~) => {
        match
          dir_check_limit("max_old_bytes", identity.size, limits.max_old_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit("max_new_bytes", identity.size, limits.max_new_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit(
            "max_output_bytes",
            identity.size,
            limits.max_output_bytes,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        let old_file = match old_by_path.get(path) {
          Some(f) => f
          None => return Err(MissingOldFile(path~))
        }
        match
          dir_verify_precomputed_identity(
            path,
            Old,
            old_file.identity,
            identity,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        restored_paths[path] = ()
        restored_files.push({
          path,
          bytes: old_file.bytes,
          identity: old_file.identity,
        })
      }
      Renamed(path~, from_path~, identity~) => {
        match
          dir_check_limit("max_old_bytes", identity.size, limits.max_old_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit("max_new_bytes", identity.size, limits.max_new_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit(
            "max_output_bytes",
            identity.size,
            limits.max_output_bytes,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        if !used_old_paths.contains(from_path) {
          used_old_paths[from_path] = ()
        } else {
          cloned_bytes = match
            dir_checked_add_i64(cloned_bytes, identity.size, "max_output_bytes") {
            Ok(v) => v
            Err(err) => return Err(err)
          }
          match
            dir_check_limit(
              "max_output_bytes",
              cloned_bytes,
              limits.max_output_bytes,
            ) {
            Ok(_) => ()
            Err(err) => return Err(err)
          }
        }
        let old_file = match old_by_path.get(from_path) {
          Some(f) => f
          None => return Err(MissingOldFile(path=from_path))
        }
        match
          dir_verify_precomputed_identity(
            from_path,
            Old,
            old_file.identity,
            identity,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        restored_paths[path] = ()
        restored_files.push({
          path,
          bytes: old_file.bytes,
          identity: old_file.identity,
        })
      }
      Patched(
        path~,
        from_path~,
        old_identity~,
        new_identity~,
        patch_identity~,
        blob_name~,
      ) => {
        match
          dir_check_limit(
            "max_old_bytes",
            old_identity.size,
            limits.max_old_bytes,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit(
            "max_patch_bytes",
            patch_identity.size,
            limits.max_patch_bytes,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit(
            "max_new_bytes",
            new_identity.size,
            limits.max_new_bytes,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit(
            "max_output_bytes",
            new_identity.size,
            limits.max_output_bytes,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        if !used_old_paths.contains(from_path) {
          used_old_paths[from_path] = ()
        } else {
          cloned_bytes = match
            dir_checked_add_i64(
              cloned_bytes,
              new_identity.size,
              "max_output_bytes",
            ) {
            Ok(v) => v
            Err(err) => return Err(err)
          }
          match
            dir_check_limit(
              "max_output_bytes",
              cloned_bytes,
              limits.max_output_bytes,
            ) {
            Ok(_) => ()
            Err(err) => return Err(err)
          }
        }
        let old_file = match old_by_path.get(from_path) {
          Some(f) => f
          None => return Err(MissingOldFile(path=from_path))
        }
        match
          dir_verify_precomputed_identity(
            from_path,
            Old,
            old_file.identity,
            old_identity,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        let patch_bytes = match blob_map.get(blob_name) {
          Some(b) => b
          None => return Err(MissingBlob(blob_name))
        }
        match
          dir_verify_content_identity(path, Patch, patch_bytes, patch_identity) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        let header = match
          @moonbsdiff.inspect_header(patch_bytes, limits.max_patch_bytes) {
          Ok(h) => h
          Err(err) => return Err(ApplyError(path~, error=err))
        }
        if header.new_bytes != new_identity.size {
          return Err(
            IdentityMismatch(
              path~,
              object=PatchTarget,
              difference=Size(
                expected=new_identity.size,
                actual=header.new_bytes,
              ),
            ),
          )
        }
        let patched_bytes = match
          @moonbsdiff.apply(old_file.bytes, patch_bytes, limits) {
          Ok(b) => b
          Err(err) => return Err(ApplyError(path~, error=err))
        }
        match
          dir_verify_content_identity(
            path,
            Restored,
            patched_bytes,
            new_identity,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        restored_paths[path] = ()
        restored_files.push({
          path,
          bytes: patched_bytes,
          identity: new_identity,
        })
      }
      Added(path~, identity~, blob_name~, full_fallback=_) => {
        match
          dir_check_limit("max_new_bytes", identity.size, limits.max_new_bytes) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        match
          dir_check_limit(
            "max_output_bytes",
            identity.size,
            limits.max_output_bytes,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        let full_bytes = match blob_map.get(blob_name) {
          Some(b) => b
          None => return Err(MissingBlob(blob_name))
        }
        match
          dir_verify_content_identity(path, Restored, full_bytes, identity) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        restored_paths[path] = ()
        restored_files.push({ path, bytes: full_bytes, identity, })
      }
      Deleted(path~, old_identity~) => {
        let old_file = match old_by_path.get(path) {
          Some(f) => f
          None => return Err(MissingOldFile(path~))
        }
        match
          dir_verify_precomputed_identity(
            path,
            Old,
            old_file.identity,
            old_identity,
          ) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
        deleted_paths[path] = ()
      }
    }
  }
  // Reject silent deletions: every old file absent from the restored tree
  // must have been explicitly declared via a Deleted entry.
  for old_file in old_sorted {
    if !restored_paths.contains(old_file.path) &&
      !deleted_paths.contains(old_file.path) {
      return Err(
        InvalidSchema(
          field="entries",
          detail="dir apply: old file absent from restored tree without Deleted entry: " +
            old_file.path,
        ),
      )
    }
  }
  // Verify final restored tree hash, count, and total bytes reusing already-verified
  // per-file identities (manifest parsing already validated path uniqueness and prefix safety).
  restored_files.sort_by((a, b) => dir_compare_utf8(a.path, b.path))
  let restored_out : Array[DirFileEntry] = []
  let restored_id_items : Array[(String, ContentIdentity)] = []
  let mut restored_total_bytes = 0L
  for file in restored_files {
    restored_out.push({ path: file.path, bytes: file.bytes, })
    restored_id_items.push((file.path, file.identity))
    restored_total_bytes = match
      dir_checked_add_i64(
        restored_total_bytes,
        file.identity.size,
        "new_total_bytes",
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
  }
  let actual_new_tree = dir_tree_sha256_from_sorted_identities(
    restored_id_items,
  )
  if actual_new_tree != manifest.new_tree_sha256 ||
    restored_out.length() != manifest.new_file_count ||
    restored_total_bytes != manifest.new_total_bytes {
    return Err(
      NewTreeMismatch(expected=manifest.new_tree_sha256, actual=actual_new_tree),
    )
  }
  Ok((restored_out, dir_summarize(manifest)))
}

///|
/// Verify the detached directory manifest signature against `keys` FIRST
/// (fail-closed before parsing the manifest or inspecting blobs), then apply the bundle.
pub fn dir_apply_signed(
  old_entries : Array[DirFileEntry],
  manifest_bytes : Bytes,
  sig : DirManifestSignature,
  keys : Array[PublicKey],
  blobs : Array[DirBlob],
  limits : @moonbsdiff.Limits,
) -> Result[(Array[DirFileEntry], DirDeltaSummary, PublicKey), DirDeltaError] {
  let verified_key = match
    verify_dir_manifest_signature_with_keys(manifest_bytes, sig, keys) {
    Ok(k) => k
    Err(err) => return Err(Signature(err))
  }
  match dir_apply(old_entries, manifest_bytes, blobs, limits) {
    Ok((restored, summary)) => Ok((restored, summary, verified_key))
    Err(err) => Err(err)
  }
}
