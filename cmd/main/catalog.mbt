///|
fn catalog_diagnostic(err : @manifest.CatalogError) -> String {
  match err {
    InvalidLimits(reason) => @debug.to_string(reason)
    InvalidEncoding => "catalog encoding: expected valid UTF-8 without BOM"
    InvalidJson(detail~, ..) => "catalog JSON: " + detail
    InvalidSchema(detail~, ..) => detail
    LimitExceeded(field~, value~, limit~) =>
      "catalog limit \{field} value \{value} exceeds limit \{limit}"
    Signature(sig_err) => signature_diagnostic(sig_err)
    CatalogHashMismatch(expected~, actual~) =>
      "catalog_sha256 mismatch: expected \{expected}, got \{actual}"
    CatalogRollback(catalog_version~, min_catalog_version~) =>
      "catalog rollback rejected: catalog_version \{catalog_version} < min_catalog_version \{min_catalog_version}"
    DowngradeRejected(current_version~, target_version~, min_version~) =>
      "downgrade rejected: current_version=\{current_version}, target_version=\{target_version}, min_version=\{min_version}"
    UnknownVersion(version~) => "unknown release version: \{version}"
    CurrentIdentityMismatch(version~, difference~) =>
      match difference {
        Size(expected~, actual~) =>
          "current file identity mismatch for version \{version}: expected \{expected} bytes, got \{actual}"
        Sha256 =>
          "current file identity mismatch for version \{version}: sha256 mismatch"
      }
    InvalidMaxSteps(v) => "invalid max_steps: \{v}"
    InvalidMaxDownloadBytes(v) => "invalid max_download_bytes: \{v}"
    NoRoute(effective_max_steps~) =>
      match effective_max_steps {
        Some(depth) =>
          "no reachable patch route (effective --max-steps=\{depth})"
        None => "no reachable patch route"
      }
    BudgetExceeded(minimum_bytes~, max_download_bytes~) =>
      "minimum download \{minimum_bytes} bytes exceeds budget \{max_download_bytes} bytes"
  }
}

///|
#borrow(path)
extern "C" fn stream_open_old(path : Bytes, cap : Int64) -> Int32 = "mbsd_stream_open_old"

///|
fn stream_file_identity(
  op : String,
  path : String,
  max_bytes : Int64,
) -> @manifest.ContentIdentity {
  if stream_open_old(path_bytes(path), max_bytes) == 0 {
    let err = @utf8.decode_lossy(io_error()[:])
    stream_abort()
    failure("\{op} read current file '\{path}': " + err)
    abort("unreachable after process exit")
  }
  let size = stream_size(0)
  let hasher = @sha2.Hasher::new(kind=@sha2.Sha256)
  let mut offset = 0L
  while offset < size {
    let count = Int64::min(4096L, size - offset).to_int()
    let chunk = stream_read(0, offset, count)
    if chunk.length() != count || io_failed() != 0 {
      let err = @utf8.decode_lossy(io_error()[:])
      stream_abort()
      failure("\{op} stream read '\{path}': " + err)
      abort("unreachable after process exit")
    }
    hasher.write(chunk[:])
    offset += count.to_int64()
  }
  if stream_expect_eof(0) == 0 {
    let err = @utf8.decode_lossy(io_error()[:])
    stream_abort()
    failure("\{op} verify EOF '\{path}': " + err)
    abort("unreachable after process exit")
  }
  stream_abort()
  if io_failed() != 0 {
    failure(
      "\{op} close current file '\{path}': " + @utf8.decode_lossy(io_error()[:]),
    )
    abort("unreachable after process exit")
  }
  let hash = @manifest_support.digest_hex(hasher.finish())
  let empty_sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  let synth = @json.Json::object({
    "schema_version": @json.Json::number(1.0),
    "patch_format": @json.Json::string("BSDIFF40"),
    "producer": @json.Json::object({
      "name": @json.Json::string("moonbsdiff"),
      "version": @json.Json::string(@manifest_support.PRODUCER_VERSION),
    }),
    "old": @json.Json::object({
      "size_bytes": @json.Json::string("0"),
      "sha256": @json.Json::string(empty_sha),
    }),
    "new": @json.Json::object({
      "size_bytes": @json.Json::string("\{size}"),
      "sha256": @json.Json::string(hash),
    }),
    "patch": @json.Json::object({
      "size_bytes": @json.Json::string("0"),
      "sha256": @json.Json::string(empty_sha),
    }),
  }).stringify()
  let cap = Int64::max(1L, size)
  let synth_limits : @moonbsdiff.Limits = {
    ..@moonbsdiff.Limits::for_apply(),
    max_new_bytes: cap,
    max_output_bytes: cap,
  }
  match @manifest.prepare_target(@utf8.encode(synth[:]), synth_limits) {
    Ok(identity) => identity
    Err(err) => {
      failure("\{op} identity for '\{path}': " + manifest_diagnostic(err))
      abort("unreachable after process exit")
    }
  }
}

///|
fn manifest_catalog_sign_command(config : CliConfig) -> Unit {
  let op = config.operation
  let priv_path = config.private_key.unwrap()
  let catalog_path = config.files[0]
  let sig_path = config.files[1]
  if !check_output_against([priv_path, catalog_path], sig_path) {
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
  let catalog_bytes = read_input(
    "\{op} read catalog (limit=\{@manifest.max_catalog_file_bytes} bytes)",
    catalog_path,
    @manifest.max_catalog_file_bytes.to_int64(),
  )
  let sig = match priv_key.sign_catalog(catalog_bytes) {
    Ok(v) => v
    Err(err) => {
      failure("\{op} '\{catalog_path}': " + catalog_diagnostic(err))
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
        "catalog_sha256": @json.Json::string(sig.catalog_sha256()),
        "catalog_path": @json.Json::string(catalog_path),
        "signature_path": @json.Json::string(sig_path),
      }).stringify(),
    )
  } else {
    println(
      "Catalog signed: algorithm ed25519, key_id \{sig.key_id()}, catalog_sha256 \{sig.catalog_sha256()}, signature_path \{sig_path}",
    )
  }
}

///|
fn load_verified_catalog(
  config : CliConfig,
  catalog_path : String,
) -> @manifest.VerifiedCatalog {
  let op = config.operation
  let sig_path = config.signature.unwrap()
  let (store, _) = match load_trust_store(op, config.public_keys) {
    Ok(v) => v
    Err(msg) => {
      failure(msg)
      abort("unreachable after process exit")
    }
  }
  let sig_bytes = read_input(
    "\{op} read signature (limit=\{@manifest.max_signature_file_bytes} bytes)",
    sig_path,
    @manifest.max_signature_file_bytes.to_int64(),
  )
  let sig = match @manifest.CatalogSignature::from_json_bytes(sig_bytes) {
    Ok(v) => v
    Err(err) => {
      failure("\{op} '\{sig_path}': " + signature_diagnostic(err))
      abort("unreachable after process exit")
    }
  }
  let catalog_bytes = read_input(
    "\{op} read catalog (limit=\{@manifest.max_catalog_file_bytes} bytes)",
    catalog_path,
    @manifest.max_catalog_file_bytes.to_int64(),
  )
  match
    store.verify_catalog(
      catalog_bytes,
      sig,
      min_catalog_version?=config.min_catalog_version,
    ) {
    Ok(v) => v
    Err(err) => {
      failure("\{op}: " + catalog_diagnostic(err))
      abort("unreachable after process exit")
    }
  }
}

///|
fn manifest_catalog_verify_command(config : CliConfig) -> Unit {
  let sig_path = config.signature.unwrap()
  let catalog_path = config.files[0]
  let verified = load_verified_catalog(config, catalog_path)
  let cat = verified.catalog
  if config.json {
    println(
      @json.Json::object({
        "schema_version": @json.Json::number(1.0),
        "valid": @json.Json::boolean(true),
        "algorithm": @json.Json::string("ed25519"),
        "signer_key_id": @json.Json::string(verified.signer_key_id),
        "catalog_sha256": @json.Json::string(verified.catalog_sha256),
        "channel": @json.Json::string(cat.channel),
        "catalog_version": @json.Json::string("\{cat.catalog_version}"),
        "min_version": @json.Json::string("\{cat.min_version}"),
        "release_count": @json.Json::number(cat.releases.length().to_double()),
        "patch_count": @json.Json::number(cat.patches.length().to_double()),
        "catalog_path": @json.Json::string(catalog_path),
        "signature_path": @json.Json::string(sig_path),
      }).stringify(),
    )
  } else {
    println(
      "Catalog signature verified: algorithm ed25519, signer_key_id \{verified.signer_key_id}, channel \{cat.channel}, catalog_version \{cat.catalog_version}, min_version \{cat.min_version}, releases \{cat.releases.length()}, patches \{cat.patches.length()}",
    )
  }
}

///|
fn manifest_catalog_plan_command(config : CliConfig) -> Unit {
  let op = config.operation
  let catalog_path = config.files[0]
  let current_path = config.files[1]
  let current_version = config.current_version.unwrap()
  let target_version = config.target_version.unwrap()
  // Fail closed: authenticate catalog and enforce anti-replay BEFORE opening CURRENT_FILE.
  let verified = load_verified_catalog(config, catalog_path)
  let current_identity = stream_file_identity(
    op,
    current_path,
    config.limits.max_old_bytes,
  )
  let plan = match
    verified.plan_update(
      current_version,
      current_identity,
      target_version,
      config.limits,
      max_steps?=config.max_steps,
      max_download_bytes?=config.max_download_bytes,
      allow_full=config.allow_full,
    ) {
    Ok(v) => v
    Err(err) => {
      failure("\{op}: " + catalog_diagnostic(err))
      return
    }
  }
  let cat = verified.catalog
  let (decision, total_download_bytes, target_rel, indices) = match plan {
    UpToDate(rel) => ("up-to-date", 0L, rel, ([] : Array[Int32]))
    FullFile(rel) => ("full-file", rel.content.size, rel, ([] : Array[Int32]))
    Patches(route) => {
      let arr : Array[Int32] = []
      for idx in route.patch_indices {
        arr.push(idx)
      }
      ("patches", route.total_patch_bytes, route.target, arr)
    }
  }
  if config.json {
    let steps_json : Array[@json.Json] = []
    for idx in indices {
      let p = cat.patches[idx]
      let mhash_json = match p.manifest_sha256 {
        Some(h) => @json.Json::string(h)
        None => @json.Json::null()
      }
      let uri_json = match p.uri {
        Some(u) => @json.Json::string(u)
        None => @json.Json::null()
      }
      steps_json.push(
        @json.Json::object({
          "patch_index": @json.Json::number(idx.to_double()),
          "from_version": @json.Json::string("\{p.from_version}"),
          "to_version": @json.Json::string("\{p.to_version}"),
          "patch_size_bytes": @json.Json::string("\{p.patch.size}"),
          "patch_sha256": @json.Json::string(p.patch.hash),
          "manifest_sha256": mhash_json,
          "uri": uri_json,
        }),
      )
    }
    println(
      @json.Json::object({
        "schema_version": @json.Json::number(1.0),
        "signer_key_id": @json.Json::string(verified.signer_key_id),
        "catalog_sha256": @json.Json::string(verified.catalog_sha256),
        "channel": @json.Json::string(cat.channel),
        "catalog_version": @json.Json::string("\{cat.catalog_version}"),
        "min_version": @json.Json::string("\{cat.min_version}"),
        "current_version": @json.Json::string("\{current_version}"),
        "target_version": @json.Json::string("\{target_version}"),
        "decision": @json.Json::string(decision),
        "total_download_bytes": @json.Json::string("\{total_download_bytes}"),
        "target": @json.Json::object({
          "version": @json.Json::string("\{target_rel.version}"),
          "label": @json.Json::string(target_rel.label),
          "size_bytes": @json.Json::string("\{target_rel.content.size}"),
          "sha256": @json.Json::string(target_rel.content.hash),
        }),
        "steps": @json.Json::array(steps_json),
      }).stringify(),
    )
  } else {
    println("Channel: \{cat.channel}")
    println(
      "Catalog version: \{cat.catalog_version} (min_version=\{cat.min_version}, signer_key_id=\{verified.signer_key_id})",
    )
    println("Decision: \{decision}")
    println(
      "Transition: v\{current_version} -> v\{target_rel.version} (\{target_rel.label})",
    )
    println("Total download bytes: \{total_download_bytes}")
    println("Steps: \{indices.length()}")
    for step_num, idx in indices {
      let p = cat.patches[idx]
      let uri_part = match p.uri {
        Some(u) => ", uri=" + u
        None => ""
      }
      println(
        "  \{step_num + 1}. [patch #\{idx}] v\{p.from_version} -> v\{p.to_version} (\{p.patch.size} bytes, sha256=\{p.patch.hash}\{uri_part})",
      )
    }
  }
}
