///|
extern "js" fn js_is_string(v : String) -> Bool =
  #| (v) => typeof v === "string"

///|
extern "js" fn js_is_number(v : Double) -> Bool =
  #| (v) => typeof v === "number"

///|
fn j_str(s : String) -> @json.Json {
  @json.Json::string(s)
}

///|
fn j_bool(b : Bool) -> @json.Json {
  @json.Json::boolean(b)
}

///|
fn j_int(v : Int32) -> @json.Json {
  @json.Json::number(v.to_double())
}

///|
fn j_i64(v : Int64) -> @json.Json {
  @json.Json::number(v.to_double())
}

///|
fn j_null() -> @json.Json {
  @json.Json::null()
}

///|
fn j_obj(fields : Map[String, @json.Json]) -> @json.Json {
  @json.Json::object(fields)
}

///|
fn j_arr(items : Array[@json.Json]) -> @json.Json {
  @json.Json::array(items)
}

///|
fn j_opt_str(opt : String?) -> @json.Json {
  match opt {
    Some(v) => j_str(v)
    None => j_null()
  }
}

///|
fn j_opt_i64(opt : Int64?) -> @json.Json {
  match opt {
    Some(v) => j_i64(v)
    None => j_null()
  }
}

///|
fn hex_nibble(byte : Byte) -> Int32? {
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
fn decode_hex_bytes_bounded(
  hex : String,
  max_bytes : Int32,
) -> Result[Bytes, (String, String)] {
  if max_bytes >= 0 && hex.length() > max_bytes * 4 + 64 {
    return Err(
      ("LimitExceeded", "hex input exceeds maximum \{max_bytes} byte cap"),
    )
  }
  let raw = @utf8.encode(hex[:])
  let out : Array[Byte] = []
  let mut hi_opt : Int32? = None
  for b in raw {
    if b == b' ' || b == b'\n' || b == b'\r' || b == b'\t' {
      continue
    }
    let nib = match hex_nibble(b) {
      Some(n) => n
      None =>
        return Err(
          ("InvalidHex", "hex input contains non-hexadecimal character"),
        )
    }
    match hi_opt {
      None => {
        if max_bytes >= 0 && out.length() >= max_bytes {
          return Err(
            (
              "LimitExceeded",
              "decoded hex payload exceeds maximum \{max_bytes} byte cap",
            ),
          )
        }
        hi_opt = Some(nib)
      }
      Some(hi) => {
        out.push(((hi << 4) | nib).to_byte())
        hi_opt = None
      }
    }
  }
  match hi_opt {
    Some(_) => Err(("InvalidHex", "hex input has odd number of nibbles"))
    None => Ok(Bytes::from_array(out))
  }
}

///|
fn decode_hex_bytes(hex : String) -> Result[Bytes, String] {
  match decode_hex_bytes_bounded(hex, 2097152) {
    Ok(b) => Ok(b)
    Err((_, msg)) => Err(msg)
  }
}

///|
fn encode_hex_bytes(bytes : Bytes) -> String {
  let out = StringBuilder(size_hint=bytes.length() * 2)
  for b in bytes {
    out.write_string(b.to_hex())
  }
  out.to_string()
}

///|
fn bytes_to_utf8_lossy(bytes : Bytes) -> String {
  @utf8.decode(bytes[:], ignore_bom=false) catch {
    _ => ""
  }
}

///|
fn permille_saved(full_bytes : Int64, delta_bytes : Int64) -> Int64 {
  if full_bytes <= 0L {
    return 0L
  }
  if delta_bytes >= full_bytes {
    return 0L
  }
  (full_bytes - delta_bytes) * 1000L / full_bytes
}

///|
fn prng_bytes(length : Int32, seed : UInt32) -> Bytes {
  let mut state = seed
  let out : Array[Byte] = []
  for _ in 0..<length {
    state = state * 1664525U + 1013904223U
    out.push((state >> 24).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
fn structured_firmware_image(length : Int32, seed : UInt32) -> Array[Byte] {
  let mut state = seed
  let out : Array[Byte] = []
  for i in 0..<length {
    state = state * 1664525U + 1013904223U
    let section = i / 512
    let byte_val = if i < 64 {
      // Deterministic binary header + magic table
      let hdr = b"MOONFW\x00\x01\x4d\x42\x53\x44\x00\x07\x00\x00"
      hdr[i % hdr.length()]
    } else if section % 3 == 0 {
      // Structured opcode/table region
      let hi = (state >> 24).reinterpret_as_int()
      ((hi & 0x7f) ^ ((i * 13) & 0xff)).to_byte()
    } else if section % 3 == 1 {
      // Lookup table with periodic structure
      ((i * 7 + section * 31) & 0xff).to_byte()
    } else {
      // High-entropy code/data section
      (state >> 24).reinterpret_as_int().to_byte()
    }
    out.push(byte_val)
  }
  out
}

///|
fn mutate_slice(
  base : Array[Byte],
  offset : Int32,
  patch_bytes : Bytes,
) -> Array[Byte] {
  let copy = Array::makei(base.length(), i => base[i])
  for i = 0; i < patch_bytes.length(); i = i + 1 {
    if offset + i >= 0 && offset + i < copy.length() {
      copy[offset + i] = patch_bytes[i]
    }
  }
  copy
}

///|
fn flip_byte_at(bytes : Bytes, index : Int32) -> Bytes {
  let arr = bytes.to_array()
  if index >= 0 && index < arr.length() {
    arr[index] = (arr[index].to_int() ^ 0x55).to_byte()
  }
  Bytes::from_array(arr)
}

///|
fn tamper_bytes(bytes : Bytes) -> Bytes {
  if bytes.length() == 0 {
    b"\x55"
  } else {
    flip_byte_at(bytes, bytes.length() / 2)
  }
}

///|
fn parse_json_object_or_empty(
  text : String,
) -> Result[Map[String, @json.Json], String] {
  let trimmed = text.trim()
  if trimmed.length() == 0 {
    return Ok(Map([]))
  }
  let parsed = @json.parse(trimmed, max_nesting_depth=16) catch {
    err => return Err("invalid request JSON: " + @debug.to_string(err))
  }
  match parsed {
    @json.Object(fields) => Ok(fields)
    _ => Err("request JSON root must be an object")
  }
}

///|
fn get_opt_string(
  fields : Map[String, @json.Json],
  key : String,
  fallback : String,
) -> String {
  match fields.get(key) {
    Some(@json.String(v)) => v
    _ => fallback
  }
}

///|
fn get_opt_bool(
  fields : Map[String, @json.Json],
  key : String,
  fallback : Bool,
) -> Bool {
  match fields.get(key) {
    Some(@json.True) => true
    Some(@json.False) => false
    _ => fallback
  }
}

///|
fn json_number_to_strict_i64(
  field : String,
  n : Double,
) -> Result[Int64, String] {
  if n != n || n - n != 0.0 {
    return Err(field + " must be a finite integer")
  }
  if n < -9007199254740991.0 || n > 9007199254740991.0 {
    return Err(field + " is outside safe integer range")
  }
  if n.floor() != n {
    return Err(field + " must be an integer (got non-integer number)")
  }
  Ok(n.to_int64())
}

///|
fn get_strict_opt_i64(
  fields : Map[String, @json.Json],
  key : String,
) -> Result[Int64?, String] {
  match fields.get(key) {
    None | Some(@json.Null) => Ok(None)
    Some(@json.Number(n, ..)) =>
      match json_number_to_strict_i64(key, n) {
        Ok(v) => Ok(Some(v))
        Err(msg) => Err(msg)
      }
    Some(_) => Err(key + " must be an integer or null")
  }
}

///|
fn get_strict_i64_or(
  fields : Map[String, @json.Json],
  key : String,
  fallback : Int64,
) -> Result[Int64, String] {
  match get_strict_opt_i64(fields, key) {
    Ok(Some(v)) => Ok(v)
    Ok(None) => Ok(fallback)
    Err(msg) => Err(msg)
  }
}

///|
fn error_kind_name(kind : @moonbsdiff.ErrorKind) -> String {
  match kind {
    InvalidConfiguration => "InvalidConfiguration"
    UnsupportedFormat => "UnsupportedFormat"
    TruncatedData => "TruncatedData"
    InvalidField => "InvalidField"
    IntegerOverflow => "IntegerOverflow"
    DecompressionFailed => "DecompressionFailed"
    OutputOutOfBounds => "OutputOutOfBounds"
    ResourceLimitExceeded => "ResourceLimitExceeded"
  }
}

///|
fn error_stage_name(stage : @moonbsdiff.ErrorStage) -> String {
  match stage {
    Configuration => "Configuration"
    Header => "Header"
    Control => "Control"
    Diff => "Diff"
    Extra => "Extra"
    Output => "Output"
    Sorting => "Sorting"
    Matching => "Matching"
  }
}

///|
fn risk_level_name(level : @moonbsdiff.RiskLevel) -> String {
  match level {
    Low => "Low"
    Elevated => "Elevated"
    High => "High"
  }
}

///|
fn bsdiff_error_json(err : @moonbsdiff.BsdiffError) -> @json.Json {
  j_obj({
    "kind": j_str(error_kind_name(err.kind)),
    "stage": j_str(error_stage_name(err.stage)),
    "block": j_opt_str(err.block),
    "offset": j_opt_i64(err.offset),
    "field": j_opt_str(err.field),
    "value": j_opt_i64(err.value),
    "limit": j_opt_i64(err.limit),
    "raw": j_str(@debug.to_string(err)),
  })
}

///|
fn signature_error_name(err : @manifest.SignatureError) -> String {
  match err {
    InvalidKeyLength(..) => "Signature(InvalidKeyLength)"
    InvalidPublicKey(..) => "Signature(InvalidPublicKey)"
    InvalidSignatureLength(..) => "Signature(InvalidSignatureLength)"
    InvalidSignatureFormat(..) => "Signature(InvalidSignatureFormat)"
    InvalidEncoding => "Signature(InvalidEncoding)"
    InvalidJson(..) => "Signature(InvalidJson)"
    InvalidSchema(..) => "Signature(InvalidSchema)"
    LimitExceeded(..) => "Signature(LimitExceeded)"
    KeyIdMismatch(..) => "Signature(KeyIdMismatch)"
    ManifestHashMismatch(..) => "Signature(ManifestHashMismatch)"
    VerificationFailed => "Signature(VerificationFailed)"
  }
}

///|
fn catalog_error_code(err : @manifest.CatalogError) -> String {
  match err {
    InvalidLimits(_) => "InvalidLimits"
    InvalidEncoding => "InvalidEncoding"
    InvalidJson(..) => "InvalidJson"
    InvalidSchema(..) => "InvalidSchema"
    LimitExceeded(..) => "LimitExceeded"
    Signature(sig_err) => signature_error_name(sig_err)
    CatalogHashMismatch(..) => "CatalogHashMismatch"
    CatalogRollback(..) => "CatalogRollback"
    DowngradeRejected(..) => "DowngradeRejected"
    UnknownVersion(..) => "UnknownVersion"
    CurrentIdentityMismatch(..) => "CurrentIdentityMismatch"
    InvalidMaxSteps(_) => "InvalidMaxSteps"
    InvalidMaxDownloadBytes(_) => "InvalidMaxDownloadBytes"
    NoRoute(..) => "NoRoute"
    BudgetExceeded(..) => "BudgetExceeded"
  }
}

///|
fn manifest_error_code(err : @manifest.ManifestError) -> String {
  match err {
    InvalidLimits(_) => "InvalidLimits"
    InvalidEncoding => "InvalidEncoding"
    InvalidJson(..) => "InvalidJson"
    InvalidSchema(..) => "InvalidSchema"
    LimitExceeded(..) => "LimitExceeded"
    IdentityMismatch(..) => "IdentityMismatch"
    HeaderError(_) => "HeaderError"
    ApplyError(_) => "ApplyError"
  }
}

///|
fn dir_delta_error_code(err : @manifest.DirDeltaError) -> String {
  match err {
    InvalidPath(..) => "InvalidPath"
    DuplicatePath(_) => "DuplicatePath"
    PathCollision(..) => "PathCollision"
    InvalidBlobName(..) => "InvalidBlobName"
    DuplicateBlob(_) => "DuplicateBlob"
    MissingBlob(_) => "MissingBlob"
    UnexpectedBlob(_) => "UnexpectedBlob"
    InvalidLimits(_) => "InvalidLimits"
    LimitExceeded(..) => "LimitExceeded"
    InvalidEncoding => "InvalidEncoding"
    InvalidJson(..) => "InvalidJson"
    InvalidSchema(..) => "InvalidSchema"
    OldTreeMismatch(..) => "OldTreeMismatch"
    NewTreeMismatch(..) => "NewTreeMismatch"
    MissingOldFile(..) => "MissingOldFile"
    IdentityMismatch(..) => "IdentityMismatch"
    ApplyError(..) => "ApplyError"
    Signature(sig_err) => signature_error_name(sig_err)
  }
}

///|
fn studio_keypair(which : Int32) -> (@manifest.PrivateKey, @manifest.PublicKey) {
  let seed_hex = match which {
    1 => "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    2 => "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
    _ => "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7"
  }
  let seed = match decode_hex_bytes(seed_hex) {
    Ok(b) => b
    Err(_) => b""
  }
  let sk = @manifest.PrivateKey::from_seed(seed).unwrap()
  (sk, sk.public_key())
}

///|
fn limits_to_json(limits : @moonbsdiff.Limits) -> @json.Json {
  j_obj({
    "max_old_bytes": j_i64(limits.max_old_bytes),
    "max_new_bytes": j_i64(limits.max_new_bytes),
    "max_patch_bytes": j_i64(limits.max_patch_bytes),
    "max_output_bytes": j_i64(limits.max_output_bytes),
    "max_decompressed_bytes": j_i64(limits.max_decompressed_bytes),
    "max_control_instructions": j_i64(limits.max_control_instructions),
  })
}
