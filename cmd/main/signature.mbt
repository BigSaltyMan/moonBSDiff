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
fn load_public_keys(
  op : String,
  paths : Array[String],
) -> Result[Array[@manifest.PublicKey], String] {
  let keys : Array[@manifest.PublicKey] = []
  for path in paths {
    let raw = match
      read_bounded_checked(
        op, "read public key", path, @manifest.max_key_file_bytes,
      ) {
      Ok(v) => v
      Err(msg) => return Err(msg)
    }
    let pk = match @manifest.PublicKey::from_json_bytes(raw) {
      Ok(v) => v
      Err(err) => return Err("\{op} '\{path}': " + signature_diagnostic(err))
    }
    keys.push(pk)
  }
  Ok(keys)
}

///|
fn load_trust_store(
  op : String,
  paths : Array[String],
) -> Result[(@manifest.TrustStore, Map[String, String]), String] {
  let keys = match load_public_keys(op, paths) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  let store = match @manifest.TrustStore::from_keys(keys) {
    Ok(v) => v
    Err(err) => return Err("\{op} public keys: " + signature_diagnostic(err))
  }
  let path_by_id : Map[String, String] = Map([])
  for i in 0..<keys.length() {
    let id = keys[i].key_id()
    if !path_by_id.contains(id) {
      path_by_id[id] = paths[i]
    }
  }
  Ok((store, path_by_id))
}

///|
fn verify_manifest_with_store(
  op : String,
  store : @manifest.TrustStore,
  manifest_bytes : Bytes,
  sig_path : String,
) -> Result[(@manifest.ManifestSignature, @manifest.PublicKey), String] {
  let sig_bytes = match
    read_bounded_checked(
      op, "read signature", sig_path, @manifest.max_signature_file_bytes,
    ) {
    Ok(v) => v
    Err(msg) => return Err(msg)
  }
  let sig = match @manifest.ManifestSignature::from_json_bytes(sig_bytes) {
    Ok(v) => v
    Err(err) => return Err("\{op} '\{sig_path}': " + signature_diagnostic(err))
  }
  match store.verify_manifest_signature(manifest_bytes, sig) {
    Ok(verified_key) => Ok((sig, verified_key))
    Err(err) => Err("\{op} signature: " + signature_diagnostic(err))
  }
}

///|
fn verify_optional_manifest_signature(
  op : String,
  manifest_bytes : Bytes,
  public_key_paths : Array[String],
  signature_path : String?,
) -> Bool {
  match (!public_key_paths.is_empty(), signature_path) {
    (true, Some(sig_path)) => {
      let (store, _) = match load_trust_store(op, public_key_paths) {
        Ok(v) => v
        Err(msg) => {
          failure(msg)
          abort("unreachable after process exit")
        }
      }
      match verify_manifest_with_store(op, store, manifest_bytes, sig_path) {
        Ok(_) => true
        Err(msg) => {
          failure(msg)
          abort("unreachable after process exit")
        }
      }
    }
    (false, None) => false
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
  public_key_paths : Array[String],
  signature_path : String?,
) -> Result[@manifest.PreparedManifest, String] {
  match (!public_key_paths.is_empty(), signature_path) {
    (true, Some(sig_path)) => {
      let (store, _) = match load_trust_store(op, public_key_paths) {
        Ok(v) => v
        Err(msg) => return Err(msg)
      }
      match verify_manifest_with_store(op, store, manifest_bytes, sig_path) {
        Ok(_) => ()
        Err(msg) => return Err(msg)
      }
      match @manifest.prepare(manifest_bytes, limits) {
        Ok(v) => Ok(v)
        Err(err) => Err("\{op} '\{manifest_path}': " + manifest_diagnostic(err))
      }
    }
    (false, None) =>
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
  let sig_path = config.signature.unwrap()
  let manifest_path = config.files[0]
  let (store, path_by_id) = match load_trust_store(op, config.public_keys) {
    Ok(v) => v
    Err(msg) => {
      failure(msg)
      return
    }
  }
  let manifest_bytes = read_input(
    "\{op} read manifest (limit=\{@manifest_support.MAX_MANIFEST_BYTES} bytes)",
    manifest_path,
    @manifest_support.MAX_MANIFEST_BYTES.to_int64(),
  )
  let (sig, verified_key) = match
    verify_manifest_with_store(op, store, manifest_bytes, sig_path) {
    Ok(v) => v
    Err(msg) => {
      failure(msg)
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
  let matched_pub_path = path_by_id
    .get(verified_key.key_id())
    .unwrap_or(config.public_keys[0])
  if config.json {
    println(
      @json.Json::object({
        "schema_version": @json.Json::number(1.0),
        "valid": @json.Json::boolean(true),
        "algorithm": @json.Json::string("ed25519"),
        "key_id": @json.Json::string(sig.key_id()),
        "manifest_sha256": @json.Json::string(sig.manifest_sha256()),
        "manifest_path": @json.Json::string(manifest_path),
        "public_key_path": @json.Json::string(matched_pub_path),
        "signature_path": @json.Json::string(sig_path),
      }).stringify(),
    )
  } else {
    println(
      "Manifest signature verified: algorithm ed25519, key_id \{sig.key_id()}, manifest_sha256 \{sig.manifest_sha256()}",
    )
  }
}
