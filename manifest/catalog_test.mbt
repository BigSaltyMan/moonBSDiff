///|
fn catalog_test_hex_nibble(byte : Byte) -> Int32 {
  let code = byte.to_int()
  if code >= 48 && code <= 57 {
    code - 48
  } else if code >= 97 && code <= 102 {
    code - 97 + 10
  } else if code >= 65 && code <= 70 {
    code - 65 + 10
  } else {
    abort("invalid test hex character")
  }
}

///|
fn catalog_test_from_hex(hex : String) -> Bytes {
  let encoded = @utf8.encode(hex[:])
  if encoded.length() % 2 != 0 {
    abort("odd hex length")
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < encoded.length() {
    let hi = catalog_test_hex_nibble(encoded[i])
    let lo = catalog_test_hex_nibble(encoded[i + 1])
    out.push(((hi << 4) | lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out)
}

///|
fn catalog_test_to_hex(bytes : Bytes) -> String {
  let out = StringBuilder(capacity=bytes.length() * 2)
  for byte in bytes {
    out.write_string(byte.to_hex())
  }
  out.to_string()
}

///|
fn catalog_test_utf8(bytes : Bytes) -> String {
  @utf8.decode(bytes[:], ignore_bom=false) catch {
    _ => abort("unexpected invalid UTF-8 in catalog test")
  }
}

///|
fn catalog_test_keypair_1() -> (@manifest.PrivateKey, @manifest.PublicKey) {
  let sk = @manifest.PrivateKey::from_seed(
    catalog_test_from_hex(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    ),
  ).unwrap()
  (sk, sk.public_key())
}

///|
fn catalog_test_keypair_2() -> (@manifest.PrivateKey, @manifest.PublicKey) {
  let sk = @manifest.PrivateKey::from_seed(
    catalog_test_from_hex(
      "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
    ),
  ).unwrap()
  (sk, sk.public_key())
}

///|
fn catalog_test_keypair_3() -> (@manifest.PrivateKey, @manifest.PublicKey) {
  let sk = @manifest.PrivateKey::from_seed(
    catalog_test_from_hex(
      "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
    ),
  ).unwrap()
  (sk, sk.public_key())
}

///|
fn catalog_test_identity(
  size : Int32,
  fill : Byte,
) -> @manifest.ContentIdentity {
  @manifest.ContentIdentity::of_bytes(Bytes::make(size, fill))
}

///|
fn catalog_test_assert_patches(
  result : Result[@manifest.CatalogUpdatePlan, @manifest.CatalogError],
  expected_bytes : Int64,
  expected_indices : Array[Int32],
  expected_target : @manifest.CatalogRelease,
) -> Unit raise {
  match result {
    Ok(@manifest.CatalogUpdatePlan::Patches(route)) => {
      assert_eq(route.total_patch_bytes, expected_bytes)
      let want : ReadOnlyArray[Int32] = ReadOnlyArray::makei(
        expected_indices.length(),
        i => expected_indices[i],
      )
      assert_eq(route.patch_indices, want)
      assert_eq(route.target, expected_target)
    }
    _ => abort("expected CatalogUpdatePlan::Patches")
  }
}

///|
fn catalog_test_sample_catalog() -> @manifest.ReleaseCatalog {
  let r1 : @manifest.CatalogRelease = {
    version: 1L,
    label: "1.0.0",
    content: catalog_test_identity(300, b'1'),
  }
  let r2 : @manifest.CatalogRelease = {
    version: 2L,
    label: "2.0.0",
    content: catalog_test_identity(300, b'2'),
  }
  let r3 : @manifest.CatalogRelease = {
    version: 3L,
    label: "3.0.0",
    content: catalog_test_identity(300, b'3'),
  }
  let p12 : @manifest.CatalogPatch = {
    from_version: 1L,
    to_version: 2L,
    patch: catalog_test_identity(100, b'a'),
    manifest_sha256: Some(catalog_test_identity(10, b'm').hash),
    uri: Some("patches/v1-to-v2.patch"),
  }
  let p23 : @manifest.CatalogPatch = {
    from_version: 2L,
    to_version: 3L,
    patch: catalog_test_identity(120, b'b'),
    manifest_sha256: None,
    uri: Some("https://cdn.example.com/patches/v2-to-v3.patch"),
  }
  let p13 : @manifest.CatalogPatch = {
    from_version: 1L,
    to_version: 3L,
    patch: catalog_test_identity(400, b'c'),
    manifest_sha256: None,
    uri: None,
  }
  @manifest.ReleaseCatalog::new("stable", 1L, 1L, [r1, r2, r3], [p12, p23, p13]).unwrap()
}

///|
test "trust store key rotation deduplication and verification" {
  // Empty key list must fail with exact InvalidSchema error.
  assert_eq(
    @manifest.TrustStore::from_keys([]),
    Err(
      @manifest.InvalidSchema(
        field="keys",
        detail="trust store must contain at least one public key",
      ),
    ),
  )

  let (sk_old, pk_old) = catalog_test_keypair_1()
  let (sk_new, pk_new) = catalog_test_keypair_2()
  let (sk_rogue, pk_rogue) = catalog_test_keypair_3()

  // Deduplication preserves first-seen order.
  let overlap = @manifest.TrustStore::from_keys([pk_old, pk_new, pk_old, pk_new]).unwrap()
  assert_eq(overlap.len(), 2)
  let expected_ids : ReadOnlyArray[String] = [pk_old.key_id(), pk_new.key_id()]
  assert_eq(overlap.key_ids(), expected_ids)
  assert_eq(overlap.find(pk_old.key_id()), Some(pk_old))
  assert_eq(overlap.find(pk_new.key_id()), Some(pk_new))
  assert_eq(overlap.find(pk_rogue.key_id()), None)

  let bundle = @manifest.diff(
    b"rotation-old-payload-0123456789",
    b"rotation-new-payload-0123456789!",
    @moonbsdiff.Limits::for_diff(),
  ).unwrap()
  let sig_old = sk_old.sign_manifest(bundle.manifest).unwrap()
  let sig_new = sk_new.sign_manifest(bundle.manifest).unwrap()
  let sig_rogue = sk_rogue.sign_manifest(bundle.manifest).unwrap()

  // Phase 1: only old key pinned.
  let store_v1 = @manifest.TrustStore::from_keys([pk_old]).unwrap()
  assert_eq(
    store_v1.verify_manifest_signature(bundle.manifest, sig_old),
    Ok(pk_old),
  )
  assert_eq(
    store_v1.verify_manifest_signature(bundle.manifest, sig_new),
    Err(
      @manifest.KeyIdMismatch(expected=pk_old.key_id(), actual=pk_new.key_id()),
    ),
  )

  // Phase 2: overlap window accepts both old and new, rejects rogue.
  assert_eq(
    overlap.verify_manifest_signature(bundle.manifest, sig_old),
    Ok(pk_old),
  )
  assert_eq(
    overlap.verify_manifest_signature(bundle.manifest, sig_new),
    Ok(pk_new),
  )
  assert_eq(
    overlap.verify_manifest_signature(bundle.manifest, sig_rogue),
    Err(
      @manifest.KeyIdMismatch(
        expected=pk_old.key_id() + "," + pk_new.key_id(),
        actual=pk_rogue.key_id(),
      ),
    ),
  )

  // Phase 3: old key retired, only new key pinned.
  let store_v2 = @manifest.TrustStore::from_keys([pk_new]).unwrap()
  assert_eq(
    store_v2.verify_manifest_signature(bundle.manifest, sig_new),
    Ok(pk_new),
  )
  assert_eq(
    store_v2.verify_manifest_signature(bundle.manifest, sig_old),
    Err(
      @manifest.KeyIdMismatch(expected=pk_new.key_id(), actual=pk_old.key_id()),
    ),
  )

  // Tampered manifest bytes fail with ManifestHashMismatch; oversized fails LimitExceeded.
  let tampered = bundle.manifest + b" "
  match overlap.verify_manifest_signature(tampered, sig_new) {
    Err(@manifest.ManifestHashMismatch(..)) => ()
    _ => abort("expected ManifestHashMismatch on tampered manifest")
  }
  assert_eq(
    overlap.verify_manifest_signature(Bytes::make(16385, b'x'), sig_new),
    Err(
      @manifest.LimitExceeded(
        field="max_manifest_bytes",
        value=16385L,
        limit=16384L,
      ),
    ),
  )
}

///|
test "verify_signed_candidates verifies all signatures before preparing any manifest" {
  let (sk1, pk1) = catalog_test_keypair_1()
  let (sk2, pk2) = catalog_test_keypair_2()
  let (sk_rogue, _) = catalog_test_keypair_3()
  let store = @manifest.TrustStore::from_keys([pk1, pk2]).unwrap()

  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let v1 = b"candidate-version-1-data-0123456789abcdef"
  let v2 = b"candidate-version-2-data-0123456789abcdef!"
  let v3 = b"candidate-version-3-data-0123456789abcdef!!"
  let b12 = @manifest.diff(v1, v2, diff_limits).unwrap()
  let b23 = @manifest.diff(v2, v3, diff_limits).unwrap()

  let sig12 = sk1.sign_manifest(b12.manifest).unwrap()
  let sig23 = sk2.sign_manifest(b23.manifest).unwrap()

  // Empty candidate list succeeds cleanly under valid limits,
  // and fails closed with InvalidLimits under invalid limits (both empty & non-empty).
  assert_true(
    @manifest.verify_signed_candidates(store, [], apply_limits)
    .unwrap()
    .is_empty(),
  )
  let invalid_limits = { ..apply_limits, max_patch_bytes: 0L, }
  match @manifest.verify_signed_candidates(store, [], invalid_limits) {
    Err(@manifest.SignedCandidateError::InvalidLimits(_)) => ()
    _ => abort("expected InvalidLimits on empty candidates with invalid limits")
  }
  match
    @manifest.verify_signed_candidates(
      store,
      [(b12.manifest, sig12)],
      invalid_limits,
    ) {
    Err(@manifest.SignedCandidateError::InvalidLimits(_)) => ()
    _ =>
      abort(
        "expected InvalidLimits on non-empty candidates with invalid limits",
      )
  }

  // Valid multi-key batch prepares and plans cleanly.
  let prepared = @manifest.verify_signed_candidates(
    store,
    [(b12.manifest, sig12), (b23.manifest, sig23)],
    apply_limits,
  ).unwrap()
  assert_eq(prepared.length(), 2)
  let route = @manifest.plan(
    @manifest.ContentIdentity::of_bytes(v1),
    @manifest.ContentIdentity::of_bytes(v3),
    prepared,
  ).unwrap()
  let want_indices : ReadOnlyArray[Int32] = [0, 1]
  assert_eq(route.candidate_indices, want_indices)

  // Poisoned candidate at index 1 (untrusted key) rejects whole batch at index 1.
  let rogue_sig = sk_rogue.sign_manifest(b23.manifest).unwrap()
  match
    @manifest.verify_signed_candidates(
      store,
      [(b12.manifest, sig12), (b23.manifest, rogue_sig)],
      apply_limits,
    ) {
    Err(
      @manifest.SignedCandidateError::Signature(
        index=1,
        error=@manifest.KeyIdMismatch(..),
      ),
    ) => ()
    _ =>
      abort("expected Signature(index=1, KeyIdMismatch) on poisoned candidate")
  }

  // Tampered candidate at index 1 rejects with ManifestHashMismatch.
  match
    @manifest.verify_signed_candidates(
      store,
      [(b12.manifest, sig12), (b23.manifest + b"!", sig23)],
      apply_limits,
    ) {
    Err(
      @manifest.SignedCandidateError::Signature(
        index=1,
        error=@manifest.ManifestHashMismatch(..),
      ),
    ) => ()
    _ => abort("expected Signature(index=1, ManifestHashMismatch)")
  }

  // Critical ordering: candidate 0 has VALID signature over INVALID JSON,
  // while candidate 1 has an INVALID signature. Must report Signature(index=1),
  // proving EVERY signature is checked BEFORE ANY manifest JSON is parsed!
  let bad_json = b"{not-valid-manifest-json"
  let bad_json_sig = sk1.sign_manifest(bad_json).unwrap()
  match
    @manifest.verify_signed_candidates(
      store,
      [(bad_json, bad_json_sig), (b23.manifest, rogue_sig)],
      apply_limits,
    ) {
    Err(
      @manifest.SignedCandidateError::Signature(
        index=1,
        error=@manifest.KeyIdMismatch(..),
      ),
    ) => ()
    _ =>
      abort(
        "expected Signature(index=1) before Manifest parse error at index 0",
      )
  }

  // When ALL signatures pass, invalid manifest or tight limits reports Manifest(index=...).
  match
    @manifest.verify_signed_candidates(
      store,
      [(b12.manifest, sig12), (bad_json, bad_json_sig)],
      apply_limits,
    ) {
    Err(
      @manifest.SignedCandidateError::Manifest(
        index=1,
        error=@manifest.InvalidJson(..),
      ),
    ) => ()
    _ =>
      abort("expected Manifest(index=1, InvalidJson) when all signatures pass")
  }
  let tight_limits = { ..apply_limits, max_new_bytes: 10L, }
  match
    @manifest.verify_signed_candidates(
      store,
      [(b12.manifest, sig12), (b23.manifest, sig23)],
      tight_limits,
    ) {
    Err(
      @manifest.SignedCandidateError::Manifest(
        index=0,
        error=@manifest.LimitExceeded(field="max_new_bytes", ..),
      ),
    ) => ()
    _ => abort("expected Manifest(index=0, LimitExceeded) under tight limits")
  }
}

///|
test "release catalog deterministic JSON roundtrip large Int64 and signing" {
  let (sk1, pk1) = catalog_test_keypair_1()
  let (sk2, pk2) = catalog_test_keypair_2()
  let store = @manifest.TrustStore::from_keys([pk1, pk2]).unwrap()

  // Include 64-bit integers beyond 2^53 to verify exact integer formatting across JS/native/wasm-gc.
  let big_ver = 9007199254740993L
  let big_ver2 = 9007199254740995L
  let h1 = catalog_test_identity(10, b'1').hash
  let h2 = catalog_test_identity(10, b'2').hash
  let hp = catalog_test_identity(40, b'p').hash
  let hm = catalog_test_identity(12, b'm').hash
  let cat_json = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-release-catalog\",\"channel\":\"stable-1.0_rc\"," +
    "\"catalog_version\":9007199254740997,\"min_version\":9007199254740993," +
    "\"releases\":[" +
    "{\"version\":\{big_ver},\"label\":\"1.0.0\",\"size_bytes\":9007199254740999,\"sha256\":\"\{h1}\"}," +
    "{\"version\":\{big_ver2},\"label\":\"2.0.0\",\"size_bytes\":0,\"sha256\":\"\{h2}\"}" +
    "],\"patches\":[" +
    "{\"from_version\":\{big_ver},\"to_version\":\{big_ver2},\"patch_size_bytes\":9007199254740993,\"patch_sha256\":\"\{hp}\",\"manifest_sha256\":\"\{hm}\",\"uri\":\"patches/v1..v2.patch\"}" +
    "]}\n")[:],
  )
  let parsed = @manifest.ReleaseCatalog::from_json_bytes(cat_json).unwrap()
  assert_eq(parsed.catalog_version, 9007199254740997L)
  assert_eq(parsed.min_version, big_ver)
  assert_eq(parsed.releases[0].version, big_ver)
  assert_eq(parsed.releases[0].content.size, 9007199254740999L)
  assert_eq(parsed.releases[1].content.size, 0L)
  assert_eq(parsed.patches[0].patch.size, big_ver)
  assert_eq(parsed.patches[0].manifest_sha256, Some(hm))
  assert_eq(parsed.patches[0].uri, Some("patches/v1..v2.patch"))

  // Canonical serialization is byte-for-byte deterministic and roundtrips cleanly.
  let canonical = parsed.to_json_bytes()
  assert_eq(canonical, cat_json)
  assert_eq(@manifest.ReleaseCatalog::from_json_bytes(canonical), Ok(parsed))

  // Sign & verify catalog with rotated key 2, plus CatalogSignature JSON roundtrip.
  let sig = sk2.sign_catalog(canonical).unwrap()
  assert_eq(sig.key_id(), pk2.key_id())
  assert_eq(sig.signature_bytes().length(), 64)
  assert_eq(catalog_test_to_hex(sig.signature_bytes()), sig.signature_hex())
  let sig_json = sig.to_json_bytes()
  assert_eq(
    catalog_test_utf8(sig_json),
    "{\"schema_version\":1,\"format\":\"moonbsdiff-catalog-signature\",\"algorithm\":\"ed25519\",\"key_id\":\"\{sig.key_id()}\",\"catalog_sha256\":\"\{sig.catalog_sha256()}\",\"signature\":\"\{sig.signature_hex()}\"}\n",
  )
  assert_eq(@manifest.CatalogSignature::from_json_bytes(sig_json), Ok(sig))

  let verified = store.verify_catalog(canonical, sig).unwrap()
  assert_eq(verified.catalog, parsed)
  assert_eq(verified.catalog_sha256, sig.catalog_sha256())
  assert_eq(verified.signer_key_id, pk2.key_id())

  // PrivateKey::sign_catalog validates schema BEFORE signing.
  match sk1.sign_catalog(b"{bad json") {
    Err(@manifest.CatalogError::InvalidJson(..)) => ()
    _ => abort("sign_catalog must reject invalid catalog JSON before signing")
  }
}

///|
test "cross domain replay rejection between manifest and catalog signatures" {
  let (sk1, pk1) = catalog_test_keypair_1()
  let (_, pk2) = catalog_test_keypair_2()
  let (sk_rogue, _) = catalog_test_keypair_3()
  let store = @manifest.TrustStore::from_keys([pk1, pk2]).unwrap()

  let catalog = catalog_test_sample_catalog()
  let catalog_bytes = catalog.to_json_bytes()
  let catalog_sig = sk1.sign_catalog(catalog_bytes).unwrap()
  let manifest_sig_on_catalog = sk1.sign_manifest(catalog_bytes).unwrap()

  // Domain check against raw mooncrypt Ed25519 verifier.
  let ed_pk = @ed25519.PublicKey::new(pk1.to_bytes()[:]) catch {
    _ => abort("unexpected ed25519 key error")
  }
  assert_false(ed_pk.verify(catalog_bytes[:], catalog_sig.signature_bytes()[:]))
  let cat_prefixed = b"moonbsdiff-catalog-ed25519-v1\x00" + catalog_bytes
  let man_prefixed = b"moonbsdiff-manifest-ed25519-v1\x00" + catalog_bytes
  assert_true(ed_pk.verify(cat_prefixed[:], catalog_sig.signature_bytes()[:]))
  assert_false(ed_pk.verify(man_prefixed[:], catalog_sig.signature_bytes()[:]))

  // Envelope cross-parse rejection in both directions.
  match
    @manifest.CatalogSignature::from_json_bytes(
      manifest_sig_on_catalog.to_json_bytes(),
    ) {
    Err(@manifest.InvalidSchema(..)) => ()
    _ => abort("CatalogSignature accepted ManifestSignature JSON")
  }
  match
    @manifest.ManifestSignature::from_json_bytes(catalog_sig.to_json_bytes()) {
    Err(@manifest.InvalidSchema(..)) => ()
    _ => abort("ManifestSignature accepted CatalogSignature JSON")
  }

  // Manifest -> Catalog cryptographic replay attack: rewrite JSON envelope fields
  // while keeping exact valid Ed25519 signature produced by sign_manifest.
  let replayed_as_catalog_json = @utf8.encode(
    ("{\"schema_version\":1,\"format\":\"moonbsdiff-catalog-signature\",\"algorithm\":\"ed25519\"," +
    "\"key_id\":\"\{manifest_sig_on_catalog.key_id()}\"," +
    "\"catalog_sha256\":\"\{manifest_sig_on_catalog.manifest_sha256()}\"," +
    "\"signature\":\"\{manifest_sig_on_catalog.signature_hex()}\"}\n")[:],
  )
  let replayed_cat_sig = @manifest.CatalogSignature::from_json_bytes(
    replayed_as_catalog_json,
  ).unwrap()
  assert_eq(
    store.verify_catalog(catalog_bytes, replayed_cat_sig),
    Err(@manifest.CatalogError::Signature(@manifest.VerificationFailed)),
  )

  // Catalog -> Manifest cryptographic replay attack: rewrite JSON envelope fields
  // while keeping exact valid Ed25519 signature produced by sign_catalog.
  let replayed_as_manifest_json = @utf8.encode(
    ("{\"schema_version\":1,\"format\":\"moonbsdiff-manifest-signature\",\"algorithm\":\"ed25519\"," +
    "\"key_id\":\"\{catalog_sig.key_id()}\"," +
    "\"manifest_sha256\":\"\{catalog_sig.catalog_sha256()}\"," +
    "\"signature\":\"\{catalog_sig.signature_hex()}\"}\n")[:],
  )
  let replayed_man_sig = @manifest.ManifestSignature::from_json_bytes(
    replayed_as_manifest_json,
  ).unwrap()
  assert_eq(
    store.verify_manifest_signature(catalog_bytes, replayed_man_sig),
    Err(@manifest.VerificationFailed),
  )
  assert_eq(
    @manifest.verify_raw_signature(
      catalog_bytes,
      catalog_sig.signature_bytes(),
      pk1,
    ),
    Err(@manifest.VerificationFailed),
  )

  // Signature is checked BEFORE JSON schema parsing on untrusted/tampered bytes.
  let rogue_sig = sk_rogue.sign_catalog(catalog_bytes).unwrap()
  match store.verify_catalog(b"{bad json", rogue_sig) {
    Err(@manifest.CatalogError::Signature(@manifest.KeyIdMismatch(..))) => ()
    _ => abort("expected Signature(KeyIdMismatch) before JSON parse")
  }
  match store.verify_catalog(b"{bad json", catalog_sig) {
    Err(@manifest.CatalogError::CatalogHashMismatch(..)) => ()
    _ => abort("expected CatalogHashMismatch before JSON parse")
  }

  // Even if raw Ed25519 validly signs invalid JSON under the catalog domain,
  // schema parsing still fails closed after signature verification.
  let raw_bad = b"{bad json"
  let ed_sk1 = @ed25519.PrivateKey::new(
    catalog_test_from_hex(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    )[:],
  ) catch {
    _ => abort("unexpected ed25519 private key error")
  }
  let bad_payload = b"moonbsdiff-catalog-ed25519-v1\x00" + raw_bad
  let raw_bad_sig = ed_sk1.sign(bad_payload[:])
  let bad_hash = @manifest.ContentIdentity::of_bytes(raw_bad).hash
  let forged_valid_sig_json = @utf8.encode(
    ("{\"schema_version\":1,\"format\":\"moonbsdiff-catalog-signature\",\"algorithm\":\"ed25519\"," +
    "\"key_id\":\"\{pk1.key_id()}\",\"catalog_sha256\":\"\{bad_hash}\"," +
    "\"signature\":\"\{catalog_test_to_hex(raw_bad_sig)}\"}\n")[:],
  )
  let forged_valid_sig = @manifest.CatalogSignature::from_json_bytes(
    forged_valid_sig_json,
  ).unwrap()
  match store.verify_catalog(raw_bad, forged_valid_sig) {
    Err(@manifest.CatalogError::InvalidJson(..)) => ()
    _ => abort("expected InvalidJson after valid signature on invalid JSON")
  }

  // Oversized catalog (> 256 KiB) rejected BEFORE UTF-8 decode or hashing.
  let oversized = Bytes::make(262145, b'\xff')
  assert_eq(
    @manifest.ReleaseCatalog::from_json_bytes(oversized),
    Err(
      @manifest.CatalogError::LimitExceeded(
        field="max_catalog_file_bytes",
        value=262145L,
        limit=262144L,
      ),
    ),
  )
  assert_eq(
    sk1.sign_catalog(oversized),
    Err(
      @manifest.CatalogError::LimitExceeded(
        field="max_catalog_file_bytes",
        value=262145L,
        limit=262144L,
      ),
    ),
  )
  assert_eq(
    store.verify_catalog(oversized, catalog_sig),
    Err(
      @manifest.CatalogError::LimitExceeded(
        field="max_catalog_file_bytes",
        value=262145L,
        limit=262144L,
      ),
    ),
  )

  // Oversized CatalogSignature (> 4096 bytes) rejected.
  assert_eq(
    @manifest.CatalogSignature::from_json_bytes(Bytes::make(4097, b'\xff')),
    Err(
      @manifest.LimitExceeded(
        field="max_signature_file_bytes",
        value=4097L,
        limit=4096L,
      ),
    ),
  )
}

///|
test "release catalog strict JSON and schema validation rejections" {
  let base = catalog_test_sample_catalog()
  let base_bytes = base.to_json_bytes()
  let base_str = catalog_test_utf8(base_bytes)

  // BOM and invalid UTF-8.
  assert_eq(
    @manifest.ReleaseCatalog::from_json_bytes(b"\xef\xbb\xbf" + base_bytes),
    Err(@manifest.CatalogError::InvalidEncoding),
  )
  assert_eq(
    @manifest.ReleaseCatalog::from_json_bytes(b"\xff\xfe"),
    Err(@manifest.CatalogError::InvalidEncoding),
  )

  // Escaped duplicate key.
  let dup = b"{\"\\u0073chema\":1," + base_bytes[1:].to_owned()
  match @manifest.ReleaseCatalog::from_json_bytes(dup) {
    Err(@manifest.CatalogError::InvalidJson(field=Some("schema"), ..)) => ()
    _ => abort("expected InvalidJson duplicate key")
  }

  // Non-object root and unknown root field.
  match @manifest.ReleaseCatalog::from_json_bytes(b"[]") {
    Err(@manifest.CatalogError::InvalidSchema(field="root", ..)) => ()
    _ => abort("expected InvalidSchema on non-object root")
  }
  let extra_root = @utf8.encode(
    base_str.replace(old="\"schema\":1,", new="\"schema\":1,\"extra\":true,")[:],
  )
  match @manifest.ReleaseCatalog::from_json_bytes(extra_root) {
    Err(@manifest.CatalogError::InvalidSchema(field="extra", ..)) => ()
    _ => abort("expected InvalidSchema on unknown root field")
  }

  // Invalid schema versions (2, 1.0, "1").
  for bad_schema in ["2", "1.0", "\"1\""] {
    let raw = @utf8.encode(
      base_str.replace(old="\"schema\":1", new="\"schema\":" + bad_schema)[:],
    )
    match @manifest.ReleaseCatalog::from_json_bytes(raw) {
      Err(@manifest.CatalogError::InvalidSchema(field="schema", ..)) => ()
      _ => abort("accepted bad catalog schema: " + bad_schema)
    }
  }

  // Wrong type.
  let bad_type = @utf8.encode(
    base_str.replace(old="\"moonbsdiff-release-catalog\"", new="\"wrong-type\"")[:],
  )
  match @manifest.ReleaseCatalog::from_json_bytes(bad_type) {
    Err(@manifest.CatalogError::InvalidSchema(field="type", ..)) => ()
    _ => abort("accepted wrong catalog type")
  }

  // Invalid channels: empty, space, slash, > 64 bytes.
  let long_channel = String::make(65, 'a')
  for bad_ch in ["", "my channel", "stable/prod", "beta@1", long_channel] {
    let raw = @utf8.encode(
      base_str.replace(
        old="\"channel\":\"stable\"",
        new="\"channel\":\"\{bad_ch}\"",
      )[:],
    )
    match @manifest.ReleaseCatalog::from_json_bytes(raw) {
      Err(@manifest.CatalogError::InvalidSchema(field="channel", ..)) => ()
      _ => abort("accepted bad channel: " + bad_ch)
    }
  }

  // Invalid catalog_version (0, -1, 1.0, Int64 overflow) and min_version (-1), valid min_version 0.
  for bad_cv in ["0", "-1", "1.0", "9223372036854775808"] {
    let raw = @utf8.encode(
      base_str.replace(
        old="\"catalog_version\":1",
        new="\"catalog_version\":" + bad_cv,
      )[:],
    )
    match @manifest.ReleaseCatalog::from_json_bytes(raw) {
      Err(@manifest.CatalogError::InvalidSchema(field="catalog_version", ..)) =>
        ()
      _ => abort("accepted bad catalog_version: " + bad_cv)
    }
  }
  let neg_min = @utf8.encode(
    base_str.replace(old="\"min_version\":1", new="\"min_version\":-1")[:],
  )
  match @manifest.ReleaseCatalog::from_json_bytes(neg_min) {
    Err(@manifest.CatalogError::InvalidSchema(field="min_version", ..)) => ()
    _ => abort("accepted negative min_version")
  }
  let zero_min = @utf8.encode(
    base_str.replace(old="\"min_version\":1", new="\"min_version\":0")[:],
  )
  assert_eq(
    @manifest.ReleaseCatalog::from_json_bytes(zero_min).unwrap().min_version,
    0L,
  )

  // Programmatic and JSON validation for releases and patches.
  let c1 = catalog_test_identity(100, b'1')
  let c2 = catalog_test_identity(100, b'2')
  let cp = catalog_test_identity(48, b'p')
  let r1 : @manifest.CatalogRelease = {
    version: 1L,
    label: "1.0.0",
    content: c1,
  }
  let r2 : @manifest.CatalogRelease = {
    version: 2L,
    label: "2.0.0",
    content: c2,
  }

  // Empty releases.
  match @manifest.ReleaseCatalog::new("stable", 1L, 0L, [], []) {
    Err(@manifest.CatalogError::InvalidSchema(field="releases", ..)) => ()
    _ => abort("accepted empty releases")
  }
  // Empty patches is allowed.
  assert_true(
    @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1], []) is Ok(_),
  )
  // Duplicate release version and duplicate label.
  match
    @manifest.ReleaseCatalog::new(
      "stable",
      1L,
      0L,
      [r1, { version: 1L, label: "1.0.1", content: c2, }],
      [],
    ) {
    Err(@manifest.CatalogError::InvalidSchema(field="releases[1].version", ..)) =>
      ()
    _ => abort("accepted duplicate release version")
  }
  match
    @manifest.ReleaseCatalog::new(
      "stable",
      1L,
      0L,
      [r1, { version: 2L, label: "1.0.0", content: c2, }],
      [],
    ) {
    Err(@manifest.CatalogError::InvalidSchema(field="releases[1].label", ..)) =>
      ()
    _ => abort("accepted duplicate release label")
  }
  // Invalid labels: empty, > 64 bytes, control chars.
  for
    bad_label in ["", String::make(65, 'v'), "1.0\n0", "1.0\u{7f}", "1.0\u{85}"] {
    match
      @manifest.ReleaseCatalog::new(
        "stable",
        1L,
        0L,
        [{ version: 1L, label: bad_label, content: c1, }],
        [],
      ) {
      Err(@manifest.CatalogError::InvalidSchema(field="releases[0].label", ..)) =>
        ()
      _ => abort("accepted invalid label")
    }
  }
  // Uppercase sha256 rejected in JSON.
  let upper_sha = @utf8.encode(
    base_str.replace(
      old=base.releases[0].content.hash,
      new=base.releases[0].content.hash.to_upper(),
    )[:],
  )
  match @manifest.ReleaseCatalog::from_json_bytes(upper_sha) {
    Err(@manifest.CatalogError::InvalidSchema(field="releases[0].sha256", ..)) =>
      ()
    _ => abort("accepted uppercase release sha256")
  }

  // Patch errors: unknown versions, self-loop, patch_size_bytes < 32, bad manifest_sha256, null optional fields.
  match
    @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
      {
        from_version: 9L,
        to_version: 2L,
        patch: cp,
        manifest_sha256: None,
        uri: None,
      },
    ]) {
    Err(
      @manifest.CatalogError::InvalidSchema(field="patches[0].from_version", ..),
    ) => ()
    _ => abort("accepted patch with unknown from_version")
  }
  match
    @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
      {
        from_version: 1L,
        to_version: 9L,
        patch: cp,
        manifest_sha256: None,
        uri: None,
      },
    ]) {
    Err(
      @manifest.CatalogError::InvalidSchema(field="patches[0].to_version", ..),
    ) => ()
    _ => abort("accepted patch with unknown to_version")
  }
  match
    @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
      {
        from_version: 1L,
        to_version: 1L,
        patch: cp,
        manifest_sha256: None,
        uri: None,
      },
    ]) {
    Err(
      @manifest.CatalogError::InvalidSchema(field="patches[0].to_version", ..),
    ) => ()
    _ => abort("accepted self-loop patch")
  }
  match
    @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
      {
        from_version: 1L,
        to_version: 2L,
        patch: catalog_test_identity(31, b's'),
        manifest_sha256: None,
        uri: None,
      },
    ]) {
    Err(
      @manifest.CatalogError::InvalidSchema(
        field="patches[0].patch_size_bytes",
        ..
      ),
    ) => ()
    _ => abort("accepted patch_size_bytes < 32")
  }
  match
    @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
      {
        from_version: 1L,
        to_version: 2L,
        patch: cp,
        manifest_sha256: Some("ABCD"),
        uri: None,
      },
    ]) {
    Err(
      @manifest.CatalogError::InvalidSchema(
        field="patches[0].manifest_sha256",
        ..
      ),
    ) => ()
    _ => abort("accepted invalid manifest_sha256")
  }
  let null_uri = @utf8.encode(
    base_str.replace(
      old="\"uri\":\"patches/v1-to-v2.patch\"",
      new="\"uri\":null",
    )[:],
  )
  match @manifest.ReleaseCatalog::from_json_bytes(null_uri) {
    Err(@manifest.CatalogError::InvalidSchema(field="patches[0].uri", ..)) => ()
    _ => abort("accepted null uri")
  }

  // URI validation: empty, > 512 bytes, control chars, percent-encoded controls,
  // multi-layer percent-encoding, backslashes, non-http(s) schemes, absolute/Windows paths,
  // and all '..' / '.' / empty segment traversal forms.
  let bad_uris = [
    "",
    String::make(513, 'x'),
    "patches/bad\n.patch",
    "patches/bad\t.patch",
    "patches/bad\u{85}.patch",
    "..",
    "../secret.patch",
    "patches/../secret.patch",
    "patches/..",
    "..\\secret.patch",
    "patches\\..\\secret.patch",
    "patches\\file.patch",
    "patches/%5cfile.patch",
    "patches/%255cfile.patch",
    "https://cdn.example.com/a%5cb.patch",
    "https://cdn.example.com/a/%2e%2e/b.patch",
    "https://cdn.example.com/a/%2E./b.patch",
    "patches/..%2fsecret.patch",
    "patches/..;/secret.patch",
    "https://cdn.example.com/a/..?x=1",
    "https://cdn.example.com/a/..#frag",
    "patches/..%00/secret.patch",
    "patches/%00",
    "patches/%0d%0a",
    "patches/%7f",
    "patches/%c2%85",
    "https://cdn.example.com/a%00b.patch",
    "https://cdn.example.com/a%0d%0aHost:evil",
    "patches/%252e%252e/secret.patch",
    "https://cdn.example.com/a/%252e%252e/b.patch",
    "patches/%25252e%25252e/secret.patch",
    "patches/%2525252e%2525252e/secret.patch",
    "patches/%252525252e%252525252e/secret.patch",
    "/etc/passwd",
    "//evil.example.com/a.patch",
    "%2fetc/passwd",
    "%252fetc/passwd",
    "C:/Windows/win.ini",
    "C:foo/bar",
    "C%3a/Windows/win.ini",
    "\\\\host\\share\\a.patch",
    "file:///etc/passwd",
    "file://localhost/etc/passwd",
    "FILE:///etc/passwd",
    "ftp://example.com/a.patch",
    "javascript:alert(1)",
    "data:text/plain,abc",
    ".",
    "./patches/a.patch",
    "patches/./a.patch",
    "patches/%2e/a.patch",
    "patches//a.patch",
    "patches/",
    "https://",
    "http:///etc/passwd",
    "https://%2f/etc/passwd",
    "https://:80/a.patch",
    "https://bad host/a.patch",
    "https://cdn.example.com/bad path.patch",
    // Red-team P1 #2 PoCs: userinfo @, authority split, Unicode whitespace/confusables,
    // malformed IPv6/port/metachars, raw non-UTF-8 C1 & overlong UTF-8, relative POSIX ambiguity.
    "https://releases.trusted.example@attacker.invalid/v1-v2.patch",
    "https://admin:secret@attacker.invalid/v1-v2.patch",
    "https://attacker.invalid@/v1-v2.patch",
    "https://@/v1-v2.patch",
    "https://attacker.invalid%2f@trusted.example/v1-v2.patch",
    "https://attacker.invalid%3f@trusted.example/v1-v2.patch",
    "https://attacker.invalid%23@trusted.example/v1-v2.patch",
    "https://\u{00A0}/v1-v2.patch",
    "https://\u{200B}/v1-v2.patch",
    "https://\u{3000}/v1-v2.patch",
    "https://cdn.example.com\u{2028}evil.invalid/v1-v2.patch",
    "https://cdn.example.com\u{FF0F}\u{FF0E}\u{FF0E}/secret",
    "https://cdn.example.com/a\u{200B}b.patch",
    "https://cdn.example.com/a\u{2029}b.patch",
    "https://cdn.example.com/a%e2%80%8bb.patch",
    "https://[::1/v1-v2.patch",
    "https://[]/v1-v2.patch",
    "https://[:1]/v1-v2.patch",
    "https://[1::2::3]/v1-v2.patch",
    "https://[::1%25eth0]/v1-v2.patch",
    "https://cdn.example.com:notaport/v1-v2.patch",
    "https://cdn.example.com:999999/v1-v2.patch",
    "https://cdn.example.com:65536/v1-v2.patch",
    "https://cdn.example.com:0/v1-v2.patch",
    "https://cdn.example.com:/v1-v2.patch",
    "https://cdn.example.com:080/v1-v2.patch",
    "https://cdn.example.com<script>\"/v1-v2.patch",
    "https://cdn.example.com/a<script>.patch",
    "https://999.999.999.999/v1-v2.patch",
    "https://2130706433/v1-v2.patch",
    "https://-bad.example.com/v1-v2.patch",
    "https://cdn.example.com/%85",
    "https://cdn.example.com/%c0%ae%c0%ae%c0%afsecret",
    "patches/v1-v2.patch?token=1#frag",
    "patches/v1 v2.patch",
    "patches/v1%20v2.patch",
    "patches/.. /secret",
    "patches/\u{FF0E}\u{FF0E}/secret",
    "patches/\u{00A0}file.patch",
  ]
  for bad_uri in bad_uris {
    match
      @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
        {
          from_version: 1L,
          to_version: 2L,
          patch: cp,
          manifest_sha256: None,
          uri: Some(bad_uri),
        },
      ]) {
      Err(@manifest.CatalogError::InvalidSchema(field="patches[0].uri", ..)) =>
        ()
      _ => abort("accepted bad uri: " + bad_uri)
    }
  }

  // Valid http://, https:// (DNS, IPv4, IPv6, valid ports), and strict relative POSIX URIs succeed.
  for
    good_uri in [
      "patches/v1-to-v2.patch", "patches/v1..v2.patch", "v1.patch", "http://cdn.example.com/patches/v1.patch",
      "http://localhost:8080/patches/v1.patch", "https://127.0.0.1:8443/patches/v1.patch",
      "https://[::1]:8443/patches/v1.patch", "https://[2001:db8::1]/patches/v1.patch",
      "https://[::ffff:192.0.2.1]/patches/v1.patch", "https://cdn.example.com:8443/patches/v1-to-v2.patch?token=1#top",
      "https://cdn.example.com/patches/a%20b.patch",
    ] {
    assert_true(
      @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
        {
          from_version: 1L,
          to_version: 2L,
          patch: cp,
          manifest_sha256: None,
          uri: Some(good_uri),
        },
      ])
      is Ok(_),
    )
  }

  // Unpaired UTF-16 surrogates rejected in ReleaseCatalog::new (label and uri).
  let supp = "\u{10000}"
  let lone_high = supp.unsafe_substring(start=0, end=1)
  let lone_low = supp.unsafe_substring(start=1, end=2)
  assert_eq(lone_high.length(), 1)
  assert_eq(lone_high[0].to_int(), 0xD800)
  assert_eq(lone_low.length(), 1)
  assert_eq(lone_low[0].to_int(), 0xDC00)
  for bad_surr in [lone_high, lone_low, lone_low + lone_high, lone_high + "x"] {
    match
      @manifest.ReleaseCatalog::new(
        "stable",
        1L,
        0L,
        [{ version: 1L, label: "v-" + bad_surr, content: c1, }],
        [],
      ) {
      Err(@manifest.CatalogError::InvalidSchema(field="releases[0].label", ..)) =>
        ()
      _ => abort("accepted unpaired UTF-16 surrogate in release label")
    }
    match
      @manifest.ReleaseCatalog::new("stable", 1L, 0L, [r1, r2], [
        {
          from_version: 1L,
          to_version: 2L,
          patch: cp,
          manifest_sha256: None,
          uri: Some("patches/" + bad_surr + ".patch"),
        },
      ]) {
      Err(@manifest.CatalogError::InvalidSchema(field="patches[0].uri", ..)) =>
        ()
      _ => abort("accepted unpaired UTF-16 surrogate in patch uri")
    }
  }

  // ReleaseCatalog::new enforces serialized JSON size <= max_catalog_file_bytes (256 KiB).
  let many_releases : Array[@manifest.CatalogRelease] = []
  for i = 1; i <= 2200; i = i + 1 {
    many_releases.push({
      version: i.to_int64(),
      label: "release-version-label-padding-\{i}",
      content: c1,
    })
  }
  match @manifest.ReleaseCatalog::new("stable", 1L, 0L, many_releases, []) {
    Err(
      @manifest.CatalogError::LimitExceeded(
        field="max_catalog_file_bytes",
        value~,
        limit=262144L,
      ),
    ) => assert_true(value > 262144L)
    _ =>
      abort(
        "ReleaseCatalog::new must reject catalog exceeding max_catalog_file_bytes",
      )
  }
}

///|
test "anti replay min_catalog_version in verify_catalog" {
  let (sk, pk) = catalog_test_keypair_1()
  let store = @manifest.TrustStore::from_keys([pk]).unwrap()
  let r1 : @manifest.CatalogRelease = {
    version: 1L,
    label: "1.0.0",
    content: catalog_test_identity(128, b'1'),
  }
  let cat = @manifest.ReleaseCatalog::new("stable", 5L, 1L, [r1], []).unwrap()
  let bytes = cat.to_json_bytes()
  let sig = sk.sign_catalog(bytes).unwrap()

  assert_true(store.verify_catalog(bytes, sig) is Ok(_))
  assert_true(store.verify_catalog(bytes, sig, min_catalog_version=0L) is Ok(_))
  assert_true(store.verify_catalog(bytes, sig, min_catalog_version=5L) is Ok(_))
  assert_eq(
    store.verify_catalog(bytes, sig, min_catalog_version=6L),
    Err(@manifest.CatalogRollback(catalog_version=5L, min_catalog_version=6L)),
  )
}

///|
test "catalog signature adversarial envelope and malleability rejections" {
  let (sk, _) = catalog_test_keypair_1()
  let cat_bytes = catalog_test_sample_catalog().to_json_bytes()
  let sig = sk.sign_catalog(cat_bytes).unwrap()
  let sig_json = sig.to_json_bytes()
  let sig_str = catalog_test_utf8(sig_json)

  // BOM and invalid UTF-8.
  assert_eq(
    @manifest.CatalogSignature::from_json_bytes(b"\xef\xbb\xbf" + sig_json),
    Err(@manifest.InvalidEncoding),
  )
  assert_eq(
    @manifest.CatalogSignature::from_json_bytes(b"\xff\xfe"),
    Err(@manifest.InvalidEncoding),
  )

  // Duplicate key, unknown key, missing key, wrong algorithm, uppercase hex.
  let dup = b"{\"key_id\":\"0000000000000000\"," + sig_json[1:].to_owned()
  match @manifest.CatalogSignature::from_json_bytes(dup) {
    Err(@manifest.InvalidJson(field=Some("key_id"), ..)) => ()
    _ => abort("expected InvalidJson duplicate key")
  }
  let extra = @utf8.encode(sig_str.replace(old="}", new=",\"extra\":1}")[:])
  match @manifest.CatalogSignature::from_json_bytes(extra) {
    Err(@manifest.InvalidSchema(field="extra", ..)) => ()
    _ => abort("expected InvalidSchema unknown key")
  }
  let bad_alg = @utf8.encode(
    sig_str.replace(old="\"ed25519\"", new="\"ed448\"")[:],
  )
  match @manifest.CatalogSignature::from_json_bytes(bad_alg) {
    Err(@manifest.InvalidSchema(field="algorithm", ..)) => ()
    _ => abort("expected InvalidSchema wrong algorithm")
  }
  let upper_sig = @utf8.encode(
    sig_str.replace(old=sig.signature_hex(), new=sig.signature_hex().to_upper())[:],
  )
  match @manifest.CatalogSignature::from_json_bytes(upper_sig) {
    Err(@manifest.InvalidSchema(field="signature", ..)) => ()
    _ => abort("expected InvalidSchema uppercase signature hex")
  }

  // Small-order torsion R point (identity point) and malleable S >= L (high bit set).
  let raw_sig = sig.signature_bytes()
  let s_hex = catalog_test_to_hex(raw_sig[32:64].to_owned())
  let torsion_r = "0100000000000000000000000000000000000000000000000000000000000000"
  let torsion_json = @utf8.encode(
    sig_str.replace(old=sig.signature_hex(), new=torsion_r + s_hex)[:],
  )
  match @manifest.CatalogSignature::from_json_bytes(torsion_json) {
    Err(@manifest.InvalidSignatureFormat(..)) => ()
    _ => abort("expected InvalidSignatureFormat on torsion R")
  }
  let bent_s = raw_sig.to_array()
  bent_s[63] = (bent_s[63].to_int() | 0x80).to_byte()
  let malleable_json = @utf8.encode(
    sig_str.replace(
      old=sig.signature_hex(),
      new=catalog_test_to_hex(Bytes::from_array(bent_s)),
    )[:],
  )
  match @manifest.CatalogSignature::from_json_bytes(malleable_json) {
    Err(@manifest.InvalidSignatureFormat(..)) => ()
    _ => abort("expected InvalidSignatureFormat on S >= L")
  }
}

///|
test "verified catalog plan_update multi-hop direct full-file ties budget and limits" {
  let (sk, pk) = catalog_test_keypair_1()
  let store = @manifest.TrustStore::from_keys([pk]).unwrap()
  let limits = @moonbsdiff.Limits::for_apply()

  let cat = catalog_test_sample_catalog()
  let bytes = cat.to_json_bytes()
  let sig = sk.sign_catalog(bytes).unwrap()
  let vc = store.verify_catalog(bytes, sig).unwrap()

  let c1 = cat.releases[0].content
  let c2 = cat.releases[1].content
  let r2 = cat.releases[1]
  let r3 = cat.releases[2]

  // UpToDate even with 0-byte download budget.
  assert_eq(
    vc.plan_update(2L, c2, 2L, limits, max_download_bytes=0L),
    Ok(@manifest.CatalogUpdatePlan::UpToDate(r2)),
  )

  // Multi-hop (100 + 120 = 220) beats direct (400) when unrestricted or max_steps=2.
  catalog_test_assert_patches(
    vc.plan_update(1L, c1, 3L, limits),
    220L,
    [0, 1],
    r3,
  )
  catalog_test_assert_patches(
    vc.plan_update(1L, c1, 3L, limits, max_steps=2L),
    220L,
    [0, 1],
    r3,
  )

  // max_steps=1 forces direct patch (400) when allow_full=false, or FullFile (300) when allow_full=true!
  catalog_test_assert_patches(
    vc.plan_update(1L, c1, 3L, limits, max_steps=1L),
    400L,
    [2],
    r3,
  )
  assert_eq(
    vc.plan_update(1L, c1, 3L, limits, max_steps=1L, allow_full=true),
    Ok(@manifest.CatalogUpdatePlan::FullFile(r3)),
  )

  // When allow_full=true and multi-hop (220) < full (300), Patches still wins!
  catalog_test_assert_patches(
    vc.plan_update(1L, c1, 3L, limits, allow_full=true),
    220L,
    [0, 1],
    r3,
  )

  // BudgetExceeded checks (both allow_full=false and allow_full=true).
  assert_eq(
    vc.plan_update(1L, c1, 3L, limits, max_download_bytes=219L),
    Err(@manifest.BudgetExceeded(minimum_bytes=220L, max_download_bytes=219L)),
  )
  catalog_test_assert_patches(
    vc.plan_update(1L, c1, 3L, limits, max_download_bytes=220L),
    220L,
    [0, 1],
    r3,
  )
  assert_eq(
    vc.plan_update(1L, c1, 3L, limits, max_download_bytes=200L, allow_full=true),
    Err(@manifest.BudgetExceeded(minimum_bytes=220L, max_download_bytes=200L)),
  )
  assert_eq(
    vc.plan_update(
      1L,
      c1,
      3L,
      limits,
      max_steps=1L,
      max_download_bytes=250L,
      allow_full=true,
    ),
    Err(@manifest.BudgetExceeded(minimum_bytes=300L, max_download_bytes=250L)),
  )
  assert_eq(
    vc.plan_update(
      1L,
      c1,
      3L,
      limits,
      max_steps=1L,
      max_download_bytes=300L,
      allow_full=true,
    ),
    Ok(@manifest.CatalogUpdatePlan::FullFile(r3)),
  )

  // Parameter validation: invalid limits, max_steps <= 0, max_download_bytes < 0.
  match vc.plan_update(1L, c1, 3L, { ..limits, max_patch_bytes: 0L, }) {
    Err(@manifest.CatalogError::InvalidLimits(_)) => ()
    _ => abort("expected InvalidLimits")
  }
  assert_eq(
    vc.plan_update(1L, c1, 3L, limits, max_steps=0L),
    Err(@manifest.CatalogError::InvalidMaxSteps(0L)),
  )
  assert_eq(
    vc.plan_update(1L, c1, 3L, limits, max_steps=-2L),
    Err(@manifest.CatalogError::InvalidMaxSteps(-2L)),
  )
  assert_eq(
    vc.plan_update(1L, c1, 3L, limits, max_download_bytes=-1L),
    Err(@manifest.InvalidMaxDownloadBytes(-1L)),
  )

  // Limits filtering: max_patch_bytes=150 excludes direct patch (400),
  // so max_steps=1 fails with NoRoute when allow_full=false, and falls back to FullFile when allow_full=true.
  let small_patch_limits = { ..limits, max_patch_bytes: 150L, }
  catalog_test_assert_patches(
    vc.plan_update(1L, c1, 3L, small_patch_limits),
    220L,
    [0, 1],
    r3,
  )
  assert_eq(
    vc.plan_update(1L, c1, 3L, small_patch_limits, max_steps=1L),
    Err(@manifest.CatalogError::NoRoute(effective_max_steps=Some(1L))),
  )
  assert_eq(
    vc.plan_update(
      1L,
      c1,
      3L,
      small_patch_limits,
      max_steps=1L,
      allow_full=true,
    ),
    Ok(@manifest.CatalogUpdatePlan::FullFile(r3)),
  )

  // Limits: max_old_bytes < current size filters out all patches; allow_full=true still serves FullFile.
  let small_old_limits = { ..limits, max_old_bytes: 299L, }
  assert_eq(
    vc.plan_update(1L, c1, 3L, small_old_limits),
    Err(@manifest.CatalogError::NoRoute(effective_max_steps=None)),
  )
  assert_eq(
    vc.plan_update(1L, c1, 3L, small_old_limits, allow_full=true),
    Ok(@manifest.CatalogUpdatePlan::FullFile(r3)),
  )

  // Limits: max_output_bytes < target size fails even when allow_full=true!
  assert_eq(
    vc.plan_update(
      1L,
      c1,
      3L,
      { ..limits, max_output_bytes: 299L, },
      allow_full=true,
    ),
    Err(
      @manifest.CatalogError::LimitExceeded(
        field="max_output_bytes",
        value=300L,
        limit=299L,
      ),
    ),
  )

  // Tie-breaking parity: equal bytes prefer fewer hops; equal bytes & hops prefer discovery order;
  // tie between patch route and FullFile prefers FullFile when allow_full=true;
  // bounded-hop track_hops finds 2-hop route even when 3-hop prefix to intermediate is cheaper.
  let t1 : @manifest.CatalogRelease = {
    version: 1L,
    label: "1",
    content: catalog_test_identity(200, b'1'),
  }
  let t2 : @manifest.CatalogRelease = {
    version: 2L,
    label: "2",
    content: catalog_test_identity(200, b'2'),
  }
  let t3 : @manifest.CatalogRelease = {
    version: 3L,
    label: "3",
    content: catalog_test_identity(200, b'3'),
  }
  let t4 : @manifest.CatalogRelease = {
    version: 4L,
    label: "4",
    content: catalog_test_identity(200, b'4'),
  }
  let tie_cat = @manifest.ReleaseCatalog::new(
    "stable",
    1L,
    1L,
    [t1, t2, t3, t4],
    [
      // 0: v1->v2 (100)
      {
        from_version: 1L,
        to_version: 2L,
        patch: catalog_test_identity(100, b'a'),
        manifest_sha256: None,
        uri: None,
      },
      // 1: v2->v3 (100) => 200 bytes in 2 hops
      {
        from_version: 2L,
        to_version: 3L,
        patch: catalog_test_identity(100, b'b'),
        manifest_sha256: None,
        uri: None,
      },
      // 2: v1->v3 (200) => 200 bytes in 1 hop (first)
      {
        from_version: 1L,
        to_version: 3L,
        patch: catalog_test_identity(200, b'c'),
        manifest_sha256: None,
        uri: None,
      },
      // 3: v1->v3 (200) => 200 bytes in 1 hop (second)
      {
        from_version: 1L,
        to_version: 3L,
        patch: catalog_test_identity(200, b'd'),
        manifest_sha256: None,
        uri: None,
      },
      // 4: v3->v4 (40)
      {
        from_version: 3L,
        to_version: 4L,
        patch: catalog_test_identity(40, b'e'),
        manifest_sha256: None,
        uri: None,
      },
    ],
  ).unwrap()
  let tie_bytes = tie_cat.to_json_bytes()
  let tie_vc = store
    .verify_catalog(tie_bytes, sk.sign_catalog(tie_bytes).unwrap())
    .unwrap()

  // v1 -> v3: 200 bytes in 1 hop (index 2) beats 200 bytes in 2 hops ([0, 1]) and later duplicate (index 3).
  catalog_test_assert_patches(
    tie_vc.plan_update(1L, t1.content, 3L, limits),
    200L,
    [2],
    t3,
  )
  // Tie between patch (200) and FullFile (200) favors FullFile when allow_full=true!
  assert_eq(
    tie_vc.plan_update(1L, t1.content, 3L, limits, allow_full=true),
    Ok(@manifest.CatalogUpdatePlan::FullFile(t3)),
  )

  // Bounded-hop track_hops test:
  // v1->v2 (40) + v2->v3 (40) = 80 (2 hops to v3, 0 steps left for v4 under max_steps=2!)
  // v1->v3 (95) + v3->v4 (40) = 135 (2 hops to v4!)
  let hop_cat = @manifest.ReleaseCatalog::new(
    "stable",
    1L,
    1L,
    [t1, t2, t3, t4],
    [
      {
        from_version: 1L,
        to_version: 2L,
        patch: catalog_test_identity(40, b'a'),
        manifest_sha256: None,
        uri: None,
      },
      {
        from_version: 2L,
        to_version: 3L,
        patch: catalog_test_identity(40, b'b'),
        manifest_sha256: None,
        uri: None,
      },
      {
        from_version: 1L,
        to_version: 3L,
        patch: catalog_test_identity(95, b'c'),
        manifest_sha256: None,
        uri: None,
      },
      {
        from_version: 3L,
        to_version: 4L,
        patch: catalog_test_identity(40, b'd'),
        manifest_sha256: None,
        uri: None,
      },
    ],
  ).unwrap()
  let hop_bytes = hop_cat.to_json_bytes()
  let hop_vc = store
    .verify_catalog(hop_bytes, sk.sign_catalog(hop_bytes).unwrap())
    .unwrap()
  catalog_test_assert_patches(
    hop_vc.plan_update(1L, t1.content, 4L, limits, max_steps=2L),
    135L,
    [2, 3],
    t4,
  )
  catalog_test_assert_patches(
    hop_vc.plan_update(1L, t1.content, 4L, limits, max_steps=3L),
    120L,
    [0, 1, 3],
    t4,
  )
}

///|
test "anti downgrade target checks intermediate hops and current identity mismatch" {
  let (sk, pk) = catalog_test_keypair_1()
  let store = @manifest.TrustStore::from_keys([pk]).unwrap()
  let limits = @moonbsdiff.Limits::for_apply()

  let r1 : @manifest.CatalogRelease = {
    version: 1L,
    label: "1.0.0",
    content: catalog_test_identity(500, b'1'),
  }
  let r2 : @manifest.CatalogRelease = {
    version: 2L,
    label: "2.0.0",
    content: catalog_test_identity(500, b'2'),
  }
  let r3 : @manifest.CatalogRelease = {
    version: 3L,
    label: "3.0.0",
    content: catalog_test_identity(500, b'3'),
  }
  let r4 : @manifest.CatalogRelease = {
    version: 4L,
    label: "4.0.0",
    content: catalog_test_identity(500, b'4'),
  }

  // Catalog with min_version=2 and cheap downgrade detour v2->v1->v4 vs forward v2->v3->v4,
  // plus overshoot-then-downgrade v1->v4->v3.
  let cat = @manifest.ReleaseCatalog::new("stable", 2L, 2L, [r1, r2, r3, r4], [
    // 0: v2 -> v1 (cheap 32-byte downgrade edge!)
    {
      from_version: 2L,
      to_version: 1L,
      patch: catalog_test_identity(32, b'd'),
      manifest_sha256: None,
      uri: None,
    },
    // 1: v1 -> v4 (cheap 32-byte edge from downgraded v1!)
    {
      from_version: 1L,
      to_version: 4L,
      patch: catalog_test_identity(32, b'e'),
      manifest_sha256: None,
      uri: None,
    },
    // 2: v2 -> v3 (100 bytes)
    {
      from_version: 2L,
      to_version: 3L,
      patch: catalog_test_identity(100, b'f'),
      manifest_sha256: None,
      uri: None,
    },
    // 3: v3 -> v4 (100 bytes)
    {
      from_version: 3L,
      to_version: 4L,
      patch: catalog_test_identity(100, b'g'),
      manifest_sha256: None,
      uri: None,
    },
    // 4: v4 -> v3 (cheap 32-byte downward edge!)
    {
      from_version: 4L,
      to_version: 3L,
      patch: catalog_test_identity(32, b'h'),
      manifest_sha256: None,
      uri: None,
    },
  ]).unwrap()
  let bytes = cat.to_json_bytes()
  let vc = store.verify_catalog(bytes, sk.sign_catalog(bytes).unwrap()).unwrap()

  // 1. target_version < min_version rejected (including staying on revoked v1!).
  assert_eq(
    vc.plan_update(1L, r1.content, 1L, limits),
    Err(
      @manifest.DowngradeRejected(
        current_version=1L,
        target_version=1L,
        min_version=2L,
      ),
    ),
  )
  // 2. target_version < current_version rejected (v3 -> v2 even though 2 >= min_version 2).
  assert_eq(
    vc.plan_update(3L, r3.content, 2L, limits),
    Err(
      @manifest.DowngradeRejected(
        current_version=3L,
        target_version=2L,
        min_version=2L,
      ),
    ),
  )
  // 3. Refuses cheap downgrade detour v2 -> v1 -> v4 (64 bytes), chooses v2 -> v3 -> v4 (200 bytes).
  catalog_test_assert_patches(
    vc.plan_update(2L, r2.content, 4L, limits),
    200L,
    [2, 3],
    r4,
  )
  // 4. Refuses overshoot-then-downgrade v1 -> v4 -> v3 (64 bytes) when no forward route exists to v3.
  assert_eq(
    vc.plan_update(1L, r1.content, 3L, limits),
    Err(@manifest.CatalogError::NoRoute(effective_max_steps=None)),
  )

  // 5. Refuses routing through revoked intermediate below min_version (min_version=3, current=1, target=4).
  let revoked_mid_cat = @manifest.ReleaseCatalog::new(
    "stable",
    3L,
    3L,
    [r1, r2, r3, r4],
    [
      // 0: v1 -> v2 (32 bytes, but v2 < min_version 3!)
      {
        from_version: 1L,
        to_version: 2L,
        patch: catalog_test_identity(32, b'a'),
        manifest_sha256: None,
        uri: None,
      },
      // 1: v2 -> v4 (32 bytes)
      {
        from_version: 2L,
        to_version: 4L,
        patch: catalog_test_identity(32, b'b'),
        manifest_sha256: None,
        uri: None,
      },
      // 2: v1 -> v3 (120 bytes, v3 >= min_version 3!)
      {
        from_version: 1L,
        to_version: 3L,
        patch: catalog_test_identity(120, b'c'),
        manifest_sha256: None,
        uri: None,
      },
      // 3: v3 -> v4 (120 bytes)
      {
        from_version: 3L,
        to_version: 4L,
        patch: catalog_test_identity(120, b'd'),
        manifest_sha256: None,
        uri: None,
      },
    ],
  ).unwrap()
  let rev_bytes = revoked_mid_cat.to_json_bytes()
  let rev_vc = store
    .verify_catalog(rev_bytes, sk.sign_catalog(rev_bytes).unwrap())
    .unwrap()
  catalog_test_assert_patches(
    rev_vc.plan_update(1L, r1.content, 4L, limits),
    240L,
    [2, 3],
    r4,
  )

  // 6. Unknown version checks.
  assert_eq(
    vc.plan_update(99L, r1.content, 99L, limits),
    Err(@manifest.UnknownVersion(version=99L)),
  )
  assert_eq(
    vc.plan_update(2L, r2.content, 99L, limits),
    Err(@manifest.UnknownVersion(version=99L)),
  )

  // 7. CurrentIdentityMismatch (size difference, sha256 difference, and on UpToDate check).
  assert_eq(
    vc.plan_update(2L, catalog_test_identity(499, b'2'), 4L, limits),
    Err(
      @manifest.CurrentIdentityMismatch(
        version=2L,
        difference=@manifest.Size(expected=500L, actual=499L),
      ),
    ),
  )
  assert_eq(
    vc.plan_update(2L, catalog_test_identity(500, b'x'), 4L, limits),
    Err(
      @manifest.CurrentIdentityMismatch(version=2L, difference=@manifest.Sha256),
    ),
  )
  assert_eq(
    vc.plan_update(2L, catalog_test_identity(500, b'x'), 2L, limits),
    Err(
      @manifest.CurrentIdentityMismatch(version=2L, difference=@manifest.Sha256),
    ),
  )
}

///|
test "end to end signed catalog plan and rotated multi-hop bsdiff restore" {
  let (sk_old, pk_old) = catalog_test_keypair_1()
  let (sk_new, pk_new) = catalog_test_keypair_2()
  let store = @manifest.TrustStore::from_keys([pk_old, pk_new]).unwrap()
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()

  let base = Bytes::make(4096, b'A')
  let v1 = base[:1000].to_owned() + b"VERSION_1_BLOCK" + base[1015:].to_owned()
  let v2 = base[:1000].to_owned() + b"VERSION_2_BLOCK" + base[1015:].to_owned()
  let v3 = base[:1000].to_owned() + b"VERSION_3_BLOCK" + base[1015:].to_owned()

  let b12 = @manifest.diff(v1, v2, diff_limits).unwrap()
  let b23 = @manifest.diff(v2, v3, diff_limits).unwrap()
  let s12 = sk_old.sign_manifest(b12.manifest).unwrap()
  let s23 = sk_new.sign_manifest(b23.manifest).unwrap()

  let c1 = @manifest.ContentIdentity::of_bytes(v1)
  let c2 = @manifest.ContentIdentity::of_bytes(v2)
  let c3 = @manifest.ContentIdentity::of_bytes(v3)
  let catalog = @manifest.ReleaseCatalog::new(
    "stable",
    10L,
    1L,
    [
      { version: 1L, label: "1.0.0", content: c1, },
      { version: 2L, label: "2.0.0", content: c2, },
      { version: 3L, label: "3.0.0", content: c3, },
    ],
    [
      {
        from_version: 1L,
        to_version: 2L,
        patch: @manifest.ContentIdentity::of_bytes(b12.patch),
        manifest_sha256: Some(
          @manifest.ContentIdentity::of_bytes(b12.manifest).hash,
        ),
        uri: Some("patches/1-to-2.patch"),
      },
      {
        from_version: 2L,
        to_version: 3L,
        patch: @manifest.ContentIdentity::of_bytes(b23.patch),
        manifest_sha256: Some(
          @manifest.ContentIdentity::of_bytes(b23.manifest).hash,
        ),
        uri: Some("patches/2-to-3.patch"),
      },
    ],
  ).unwrap()

  let cat_bytes = catalog.to_json_bytes()
  let cat_sig = sk_new.sign_catalog(cat_bytes).unwrap()
  let verified = store
    .verify_catalog(cat_bytes, cat_sig, min_catalog_version=10L)
    .unwrap()

  let route = match
    verified.plan_update(1L, c1, 3L, apply_limits, allow_full=true) {
    Ok(@manifest.CatalogUpdatePlan::Patches(route)) => route
    _ => abort("expected multi-hop patch route over 4096-byte full file")
  }
  let want : ReadOnlyArray[Int32] = [0, 1]
  assert_eq(route.patch_indices, want)
  assert_true(route.total_patch_bytes < c3.size)

  let prepared = @manifest.verify_signed_candidates(
    store,
    [(b12.manifest, s12), (b23.manifest, s23)],
    apply_limits,
  ).unwrap()
  let patches = [b12.patch, b23.patch]
  let mut current = v1
  for idx in route.patch_indices {
    current = prepared[idx].restore(current, patches[idx]).unwrap()
  }
  assert_eq(current, v3)
}
