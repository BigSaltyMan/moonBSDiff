///|
#borrow(out)
extern "C" fn c_random_bytes(out : FixedArray[Byte]) -> Int32 = "mbsd_random_bytes"

///|
#borrow(name, data)
extern "C" fn c_deliver_secret(name : Bytes, data : Bytes) -> Int32 = "mbsd_deliver_secret"

///|
fn io_random_bytes(count : Int32) -> Bytes {
  if count < 0 {
    failure("generate cryptographic random bytes: negative count")
    abort("unreachable after process exit")
  }
  let buf = FixedArray::make(count, b'\x00')
  if c_random_bytes(buf) == 0 {
    failure(
      "generate cryptographic random bytes: " +
      @utf8.decode_lossy(io_error()[:]),
    )
    abort("unreachable after process exit")
  }
  let seed = Bytes::makei(count, i => buf[i])
  for i in 0..<count {
    buf[i] = b'\x00'
  }
  seed
}

///|
fn io_deliver_secret(op : String, path : String, data : Bytes) -> Unit {
  if c_deliver_secret(path_bytes(path), data) == 0 {
    let detail = @utf8.decode_lossy(io_error()[:])
    let state = if delivered_output() != 0 &&
      !detail.has_prefix("output already delivered;") {
      "output already delivered; "
    } else {
      ""
    }
    failure("\{op} secret write/deliver '\{path}': \{state}\{detail}")
  }
}

///|
fn signature_diagnostic(err : @manifest.SignatureError) -> String {
  match err {
    InvalidKeyLength(expected~, actual~) =>
      "invalid key length: expected \{expected} bytes, got \{actual}"
    InvalidPublicKey(detail~) => "invalid public key: " + detail
    InvalidSignatureLength(expected~, actual~) =>
      "invalid signature length: expected \{expected} bytes, got \{actual}"
    InvalidSignatureFormat(detail~) => "invalid signature format: " + detail
    InvalidEncoding =>
      "key/signature encoding: expected valid UTF-8 without BOM"
    InvalidJson(detail~, ..) => "key/signature JSON: " + detail
    InvalidSchema(detail~, ..) => detail
    LimitExceeded(field~, value~, limit~) =>
      "signature/key limit \{field} value \{value} exceeds limit \{limit}"
    KeyIdMismatch(expected~, actual~) =>
      "key_id mismatch: expected \{expected}, got \{actual}"
    ManifestHashMismatch(expected~, actual~) =>
      "manifest_sha256 mismatch: expected \{expected}, got \{actual}"
    VerificationFailed => "Ed25519 manifest signature verification failed"
  }
}

///|
fn signed_manifest_diagnostic(err : @manifest.SignedManifestError) -> String {
  match err {
    Signature(sig_err) => signature_diagnostic(sig_err)
    Manifest(man_err) => manifest_diagnostic(man_err)
  }
}

///|
fn read_bounded_checked(
  op : String,
  label : String,
  path : String,
  cap : Int32,
) -> Result[Bytes, String] {
  let data = io_read(path_bytes(path), cap)
  if io_failed() != 0 {
    Err(
      "\{op} \{label} (limit=\{cap} bytes) '\{path}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
  } else {
    Ok(data)
  }
}

///|
fn verify_optional_manifest_signature(
  op : String,
  manifest_bytes : Bytes,
  public_key_path : String?,
  signature_path : String?,
) -> Bool {
  match (public_key_path, signature_path) {
    (Some(pub_path), Some(sig_path)) => {
      let pub_bytes = read_input(
        "\{op} read public key (limit=\{@manifest.max_key_file_bytes} bytes)",
        pub_path,
        @manifest.max_key_file_bytes.to_int64(),
      )
      let sig_bytes = read_input(
        "\{op} read signature (limit=\{@manifest.max_signature_file_bytes} bytes)",
        sig_path,
        @manifest.max_signature_file_bytes.to_int64(),
      )
      match
        @manifest.verify_manifest_signature_bytes(
          manifest_bytes, sig_bytes, pub_bytes,
        ) {
        Ok(_) => true
        Err(err) => {
          failure("\{op} signature: " + signature_diagnostic(err))
          abort("unreachable after process exit")
        }
      }
    }
    (None, None) => false
    _ => {
      failure("\{op}: --public-key and --signature must be provided together")
      abort("unreachable after process exit")
    }
  }
}

///|
fn prepare_optional_signed_manifest(
  op : String,
  manifest_path : String,
  manifest_bytes : Bytes,
  limits : @moonbsdiff.Limits,
  public_key_path : String?,
  signature_path : String?,
) -> Result[@manifest.PreparedManifest, String] {
  match (public_key_path, signature_path) {
    (Some(pub_path), Some(sig_path)) => {
      let pub_bytes = match
        read_bounded_checked(
          op, "read public key", pub_path, @manifest.max_key_file_bytes,
        ) {
        Ok(v) => v
        Err(msg) => return Err(msg)
      }
      let sig_bytes = match
        read_bounded_checked(
          op, "read signature", sig_path, @manifest.max_signature_file_bytes,
        ) {
        Ok(v) => v
        Err(msg) => return Err(msg)
      }
      let pub_key = match @manifest.PublicKey::from_json_bytes(pub_bytes) {
        Ok(v) => v
        Err(err) =>
          return Err("\{op} '\{pub_path}': " + signature_diagnostic(err))
      }
      let sig = match @manifest.ManifestSignature::from_json_bytes(sig_bytes) {
        Ok(v) => v
        Err(err) =>
          return Err("\{op} '\{sig_path}': " + signature_diagnostic(err))
      }
      match @manifest.prepare_signed(manifest_bytes, sig, pub_key, limits) {
        Ok(v) => Ok(v)
        Err(err) =>
          Err("\{op} '\{manifest_path}': " + signed_manifest_diagnostic(err))
      }
    }
    (None, None) =>
      match @manifest.prepare(manifest_bytes, limits) {
        Ok(v) => Ok(v)
        Err(err) => Err("\{op} '\{manifest_path}': " + manifest_diagnostic(err))
      }
    _ => Err("\{op}: --public-key and --signature must be provided together")
  }
}

///|
fn manifest_keygen_command(config : CliConfig) -> Unit {
  let op = config.operation
  let priv_path = config.files[0]
  let pub_path = config.files[1]
  if !check_output_against([], priv_path) {
    failure(
      "\{op} private key output '\{priv_path}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  if !check_output_against([], pub_path) {
    failure(
      "\{op} public key output '\{pub_path}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  if io_pair_check(path_bytes(priv_path), path_bytes(pub_path)) == 0 {
    failure("\{op} key output conflict: " + @utf8.decode_lossy(io_error()[:]))
    return
  }
  let seed = io_random_bytes(32)
  let priv_key = match @manifest.PrivateKey::from_seed(seed) {
    Ok(v) => v
    Err(err) => {
      failure("\{op}: " + signature_diagnostic(err))
      return
    }
  }
  let pub_key = priv_key.public_key()
  io_deliver_secret(op, priv_path, priv_key.to_json_bytes())
  if io_deliver(path_bytes(pub_path), pub_key.to_json_bytes()) == 0 {
    let detail = @utf8.decode_lossy(io_error()[:])
    let state = if delivered_output() != 0 {
      "delivered with an error"
    } else {
      "not completed"
    }
    failure(
      "private key delivered to '\{priv_path}'; public key \{state} at '\{pub_path}': \{detail}; no rollback attempted",
    )
    return
  }
  if config.json {
    println(
      @json.Json::object({
        "schema_version": @json.Json::number(1.0),
        "algorithm": @json.Json::string("ed25519"),
        "key_id": @json.Json::string(pub_key.key_id()),
        "public_key": @json.Json::string(pub_key.to_hex()),
        "private_key_path": @json.Json::string(priv_path),
        "public_key_path": @json.Json::string(pub_path),
      }).stringify(),
    )
  } else {
    println(
      "Generated Ed25519 keypair: key_id=\{pub_key.key_id()}, private_key_path=\{priv_path}, public_key_path=\{pub_path}",
    )
  }
}

///|
fn manifest_sign_command(config : CliConfig) -> Unit {
  let op = config.operation
  let priv_path = config.private_key.unwrap()
  let manifest_path = config.files[0]
  let sig_path = config.files[1]
  if !check_output_against([priv_path, manifest_path], sig_path) {
    failure("\{op} output '\{sig_path}': " + @utf8.decode_lossy(io_error()[:]))
    return
  }
  let priv_bytes = read_input(
    "\{op} read private key (limit=\{@manifest.max_key_file_bytes} bytes)",
    priv_path,
    @manifest.max_key_file_bytes.to_int64(),
  )
  let priv_key = match @manifest.PrivateKey::from_json_bytes(priv_bytes) {
    Ok(v) => v
    Err(err) => {
      failure("\{op} '\{priv_path}': " + signature_diagnostic(err))
      return
    }
  }
  let manifest_bytes = read_input(
    "\{op} read manifest (limit=\{@manifest_support.MAX_MANIFEST_BYTES} bytes)",
    manifest_path,
    @manifest_support.MAX_MANIFEST_BYTES.to_int64(),
  )
  match @manifest.validate_manifest_schema(manifest_bytes) {
    Ok(_) => ()
    Err(err) => {
      failure("\{op} '\{manifest_path}': " + manifest_diagnostic(err))
      return
    }
  }
  let sig = match priv_key.sign_manifest(manifest_bytes) {
    Ok(v) => v
    Err(err) => {
      failure("\{op}: " + signature_diagnostic(err))
      return
    }
  }
  if io_deliver(path_bytes(sig_path), sig.to_json_bytes()) == 0 {
    failure(
      "\{op} write/deliver '\{sig_path}': " + @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  if config.json {
    println(
      @json.Json::object({
        "schema_version": @json.Json::number(1.0),
        "algorithm": @json.Json::string("ed25519"),
        "key_id": @json.Json::string(sig.key_id()),
        "manifest_sha256": @json.Json::string(sig.manifest_sha256()),
        "manifest_path": @json.Json::string(manifest_path),
        "signature_path": @json.Json::string(sig_path),
      }).stringify(),
    )
  } else {
    println(
      "Manifest signed: algorithm ed25519, key_id \{sig.key_id()}, manifest_sha256 \{sig.manifest_sha256()}, signature_path \{sig_path}",
    )
  }
}

///|
fn manifest_verify_sig_command(config : CliConfig) -> Unit {
  let op = config.operation
  let pub_path = config.public_key.unwrap()
  let sig_path = config.signature.unwrap()
  let manifest_path = config.files[0]
  let pub_bytes = read_input(
    "\{op} read public key (limit=\{@manifest.max_key_file_bytes} bytes)",
    pub_path,
    @manifest.max_key_file_bytes.to_int64(),
  )
  let sig_bytes = read_input(
    "\{op} read signature (limit=\{@manifest.max_signature_file_bytes} bytes)",
    sig_path,
    @manifest.max_signature_file_bytes.to_int64(),
  )
  let manifest_bytes = read_input(
    "\{op} read manifest (limit=\{@manifest_support.MAX_MANIFEST_BYTES} bytes)",
    manifest_path,
    @manifest_support.MAX_MANIFEST_BYTES.to_int64(),
  )
  let sig = match
    @manifest.verify_manifest_signature_bytes(
      manifest_bytes, sig_bytes, pub_bytes,
    ) {
    Ok(v) => v
    Err(err) => {
      failure("\{op}: " + signature_diagnostic(err))
      return
    }
  }
  match @manifest.validate_manifest_schema(manifest_bytes) {
    Ok(_) => ()
    Err(err) => {
      failure("\{op} '\{manifest_path}': " + manifest_diagnostic(err))
      return
    }
  }
  if config.json {
    println(
      @json.Json::object({
        "schema_version": @json.Json::number(1.0),
        "valid": @json.Json::boolean(true),
        "algorithm": @json.Json::string("ed25519"),
        "key_id": @json.Json::string(sig.key_id()),
        "manifest_sha256": @json.Json::string(sig.manifest_sha256()),
        "manifest_path": @json.Json::string(manifest_path),
        "public_key_path": @json.Json::string(pub_path),
        "signature_path": @json.Json::string(sig_path),
      }).stringify(),
    )
  } else {
    println(
      "Manifest signature verified: algorithm ed25519, key_id \{sig.key_id()}, manifest_sha256 \{sig.manifest_sha256()}",
    )
  }
}
