///|
fn dir_test_hex_nibble(byte : Byte) -> Int32 {
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
fn dir_test_from_hex(hex : String) -> Bytes {
  let encoded = @utf8.encode(hex[:])
  if encoded.length() % 2 != 0 {
    abort("odd hex length")
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < encoded.length() {
    let hi = dir_test_hex_nibble(encoded[i])
    let lo = dir_test_hex_nibble(encoded[i + 1])
    out.push(((hi << 4) | lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out)
}

///|
fn dir_test_utf8_decode(bytes : Bytes) -> String {
  @utf8.decode(bytes[:], ignore_bom=false) catch {
    _ => abort("unexpected invalid UTF-8 in dir bundle test")
  }
}

///|
fn dir_test_pattern_bytes(len : Int32, seed : Int32) -> Bytes {
  let out : Array[Byte] = []
  let mut state = seed
  for i = 0; i < len; i = i + 1 {
    state = (state * 1103515245 + 12345 + i) & 0x7fffffff
    out.push(((state >> 16) & 0xff).to_byte())
  }
  Bytes::from_array(out)
}

///|
fn dir_test_patch_slice(
  base : Bytes,
  offset : Int32,
  replacement : Bytes,
) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < base.length(); i = i + 1 {
    if i >= offset && i < offset + replacement.length() {
      out.push(replacement[i - offset])
    } else {
      out.push(base[i])
    }
  }
  Bytes::from_array(out)
}

///|
fn dir_test_blobs_to_array(
  blobs : ReadOnlyArray[@manifest.DirBlob],
) -> Array[@manifest.DirBlob] {
  let out : Array[@manifest.DirBlob] = []
  for blob in blobs {
    out.push(blob)
  }
  out
}

///|
fn dir_test_repeat_char(ch : String, count : Int32) -> String {
  let sb = StringBuilder(capacity=count)
  for _i = 0; _i < count; _i = _i + 1 {
    sb.write_string(ch)
  }
  sb.to_string()
}

///|
test "dir bundle path safety validation and canonical tree_sha256" {
  // Valid POSIX relative paths.
  let valid_paths = [
    "README.md",
    "bin/app",
    "assets/v1.0/.env",
    "a..b/c",
    "dir/sub:name",
    "日本語/ファイル.bin",
    dir_test_repeat_char("a", 1024),
    dir_test_repeat_char("日", 341) + "a",
  ]
  for path in valid_paths {
    assert_eq(@manifest.validate_relative_path(path), Ok(()))
  }

  // Rejected invalid paths.
  let invalid_paths = [
    "",
    dir_test_repeat_char("a", 1025),
    dir_test_repeat_char("日", 342),
    "../escape",
    "a/../b",
    "/abs/path",
    "/",
    "a\\b",
    "C:foo",
    "C:foo/bar",
    "a//b",
    "./x",
    "a/./b",
    ".",
    "..",
    "a/",
    "a\u{0000}b",
    "a\nb",
    "a\u{001f}b",
    "a\u{007f}b",
    "a\u{0080}b",
    "a\u{0085}b",
    "a\u{009f}b",
    "a" + "\u{10000}".unsafe_substring(start=0, end=1) + "b",
    "a" + "\u{10000}".unsafe_substring(start=1, end=2) + "b",
  ]
  for path in invalid_paths {
    match @manifest.validate_relative_path(path) {
      Err(@manifest.InvalidPath(..)) => ()
      other =>
        abort(
          "expected InvalidPath for \{path}, got \{@debug.to_string(other)}",
        )
    }
  }

  // Duplicate path rejection.
  let dup_tree : Array[@manifest.DirFileEntry] = [
    { path: "dup/file.txt", bytes: b"one", },
    { path: "dup/file.txt", bytes: b"two", },
  ]
  assert_eq(
    @manifest.tree_sha256(dup_tree),
    Err(@manifest.DuplicatePath("dup/file.txt")),
  )

  // File-vs-directory prefix collisions (both direct and separated by '-' / '.').
  let direct_collision : Array[@manifest.DirFileEntry] = [
    { path: "a", bytes: b"file", },
    { path: "a/b", bytes: b"nested", },
  ]
  assert_eq(
    @manifest.tree_sha256(direct_collision),
    Err(@manifest.PathCollision(a="a", b="a/b")),
  )
  let non_adjacent_collision : Array[@manifest.DirFileEntry] = [
    { path: "foo/bar/baz", bytes: b"deep", },
    { path: "foo-extra", bytes: b"dash", },
    { path: "foo.txt", bytes: b"dot", },
    { path: "foo", bytes: b"file", },
  ]
  assert_eq(
    @manifest.tree_sha256(non_adjacent_collision),
    Err(@manifest.PathCollision(a="foo", b="foo/bar/baz")),
  )

  // Canonical order invariance and empty tree hash.
  let empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  assert_eq(@manifest.tree_sha256([]), Ok(empty_hash))
  let tree_a : Array[@manifest.DirFileEntry] = [
    { path: "z.txt", bytes: b"zeta", },
    { path: "a/b.txt", bytes: b"beta", },
    { path: "a/a.txt", bytes: b"alpha", },
  ]
  let tree_b : Array[@manifest.DirFileEntry] = [
    { path: "a/a.txt", bytes: b"alpha", },
    { path: "z.txt", bytes: b"zeta", },
    { path: "a/b.txt", bytes: b"beta", },
  ]
  assert_eq(@manifest.tree_sha256(tree_a), @manifest.tree_sha256(tree_b))

  // UTF-8 byte order invariance across supplementary plane vs BMP (> 0xDFFF).
  let u_a : Array[@manifest.DirFileEntry] = [
    { path: "\u{10000}.bin", bytes: b"1", },
    { path: "\u{E000}.bin", bytes: b"2", },
  ]
  let u_b : Array[@manifest.DirFileEntry] = [
    { path: "\u{E000}.bin", bytes: b"2", },
    { path: "\u{10000}.bin", bytes: b"1", },
  ]
  assert_eq(@manifest.tree_sha256(u_a), @manifest.tree_sha256(u_b))
}

///|
test "dir bundle realistic multi-file app update round trip" {
  let logo_bytes = dir_test_pattern_bytes(1024, 17)
  let guide_bytes = dir_test_pattern_bytes(2048, 29)
  let app_old = dir_test_pattern_bytes(4096, 43)
  let app_new = dir_test_patch_slice(
    app_old, 1500, b"moonbsdiff-v0.7.0-release-binary",
  )
  let version_old = b"v1.0.0\n"
  let version_new = b"v2.0.0\n"
  let new_banner = b"Welcome to MoonBSDiff 0.7.0 directory deltas!\n"
  let deprecated_bytes = dir_test_pattern_bytes(512, 71)

  // Provide old & new entries out of sorted order to verify deterministic output.
  let old_entries : Array[@manifest.DirFileEntry] = [
    { path: "legacy/deprecated.dat", bytes: deprecated_bytes, },
    { path: "config/version.txt", bytes: version_old, },
    { path: "docs/old-guide.md", bytes: guide_bytes, },
    { path: "bin/app.bin", bytes: app_old, },
    { path: "assets/logo.png", bytes: logo_bytes, },
  ]
  let new_entries : Array[@manifest.DirFileEntry] = [
    { path: "docs/guide.md", bytes: guide_bytes, },
    { path: "assets/new-banner.txt", bytes: new_banner, },
    { path: "config/version.txt", bytes: version_new, },
    { path: "assets/logo.png", bytes: logo_bytes, },
    { path: "bin/app.bin", bytes: app_new, },
  ]

  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let bundle = @manifest.dir_diff(old_entries, new_entries, diff_limits).unwrap()

  // Verify manifest JSON round-trip and canonical determinism.
  let reparsed = @manifest.DirManifest::from_json_bytes(bundle.manifest_bytes).unwrap()
  assert_eq(reparsed, bundle.manifest)
  assert_eq(reparsed.to_json_bytes(), bundle.manifest_bytes)

  // Verify exact counts and action classification.
  let summary = @manifest.dir_summarize(bundle.manifest)
  assert_eq(summary.unchanged_count, 1)
  assert_eq(summary.renamed_count, 1)
  assert_eq(summary.patched_count, 1)
  assert_eq(summary.added_count, 2)
  assert_eq(summary.full_fallback_count, 1)
  assert_eq(summary.deleted_count, 2)
  assert_eq(bundle.manifest.old_file_count, 5)
  assert_eq(bundle.manifest.new_file_count, 5)
  assert_eq(
    bundle.manifest.old_tree_sha256,
    @manifest.tree_sha256(old_entries).unwrap(),
  )
  assert_eq(
    bundle.manifest.new_tree_sha256,
    @manifest.tree_sha256(new_entries).unwrap(),
  )

  // Verify exact actions & 0 payload bytes for unchanged/renamed/deleted.
  let mut saw_unchanged = false
  let mut saw_renamed = false
  let mut saw_patched = false
  let mut saw_fallback = false
  let mut saw_brand_new = false
  let mut saw_deleted_old_guide = false
  let mut saw_deleted_legacy = false
  for entry in bundle.manifest.entries {
    match entry {
      @manifest.Unchanged(path="assets/logo.png", identity~) => {
        assert_true(identity == @manifest.ContentIdentity::of_bytes(logo_bytes))
        saw_unchanged = true
      }
      @manifest.Renamed(
        path="docs/guide.md",
        from_path="docs/old-guide.md",
        identity~,
      ) => {
        assert_true(
          identity == @manifest.ContentIdentity::of_bytes(guide_bytes),
        )
        saw_renamed = true
      }
      @manifest.Patched(
        path="bin/app.bin",
        from_path="bin/app.bin",
        old_identity~,
        new_identity~,
        patch_identity~,
        blob_name~,
      ) => {
        assert_true(
          old_identity == @manifest.ContentIdentity::of_bytes(app_old),
        )
        assert_true(
          new_identity == @manifest.ContentIdentity::of_bytes(app_new),
        )
        assert_true(patch_identity.size < new_identity.size)
        assert_true(blob_name.has_suffix(".patch"))
        saw_patched = true
      }
      @manifest.Added(
        path="config/version.txt",
        identity~,
        blob_name~,
        full_fallback=true,
      ) => {
        assert_true(
          identity == @manifest.ContentIdentity::of_bytes(version_new),
        )
        assert_true(blob_name.has_suffix(".full"))
        saw_fallback = true
      }
      @manifest.Added(
        path="assets/new-banner.txt",
        identity~,
        blob_name~,
        full_fallback=false,
      ) => {
        assert_true(identity == @manifest.ContentIdentity::of_bytes(new_banner))
        assert_true(blob_name.has_suffix(".full"))
        saw_brand_new = true
      }
      @manifest.Deleted(path="docs/old-guide.md", old_identity~) => {
        assert_true(
          old_identity == @manifest.ContentIdentity::of_bytes(guide_bytes),
        )
        saw_deleted_old_guide = true
      }
      @manifest.Deleted(path="legacy/deprecated.dat", old_identity~) => {
        assert_true(
          old_identity == @manifest.ContentIdentity::of_bytes(deprecated_bytes),
        )
        saw_deleted_legacy = true
      }
      other => abort("unexpected entry action: \{@debug.to_string(other)}")
    }
  }
  assert_true(saw_unchanged)
  assert_true(saw_renamed)
  assert_true(saw_patched)
  assert_true(saw_fallback)
  assert_true(saw_brand_new)
  assert_true(saw_deleted_old_guide)
  assert_true(saw_deleted_legacy)

  // Verify delta payload equals exact sum of the 3 emitted blobs and saves major bandwidth.
  assert_eq(bundle.blobs.length(), 3)
  let mut blob_sum = 0L
  for blob in bundle.blobs {
    blob_sum = blob_sum + blob.bytes.length().to_int64()
  }
  assert_eq(summary.delta_payload_bytes, blob_sum)
  assert_true(summary.delta_payload_bytes < summary.new_total_bytes / 4L)

  // Apply and verify byte-exact restoration and tree_sha256 match.
  let blobs_arr = dir_test_blobs_to_array(bundle.blobs)
  let (restored, applied_summary) = @manifest.dir_apply(
    old_entries,
    bundle.manifest_bytes,
    blobs_arr,
    apply_limits,
  ).unwrap()
  assert_eq(applied_summary, summary)
  assert_eq(
    @manifest.tree_sha256(restored),
    Ok(bundle.manifest.new_tree_sha256),
  )
  let expected_sorted : Array[@manifest.DirFileEntry] = [
    { path: "assets/logo.png", bytes: logo_bytes, },
    { path: "assets/new-banner.txt", bytes: new_banner, },
    { path: "bin/app.bin", bytes: app_new, },
    { path: "config/version.txt", bytes: version_new, },
    { path: "docs/guide.md", bytes: guide_bytes, },
  ]
  assert_eq(restored, expected_sorted)
}

///|
test "dir bundle rename selection prefers absent old path and lowest sorted path" {
  let shared = b"identical-content-payload-for-rename-preference"
  // Case 1: prefer old path absent from new over lower-sorted path still in new.
  let old1 : Array[@manifest.DirFileEntry] = [
    { path: "a_kept.dat", bytes: shared, },
    { path: "z_removed.dat", bytes: shared, },
  ]
  let new1 : Array[@manifest.DirFileEntry] = [
    { path: "a_kept.dat", bytes: shared, },
    { path: "m_moved.dat", bytes: shared, },
  ]
  let b1 = @manifest.dir_diff(old1, new1, @moonbsdiff.Limits::for_diff()).unwrap()
  let mut found_rename1 = false
  for e in b1.manifest.entries {
    if e is @manifest.Renamed(path="m_moved.dat", from_path="z_removed.dat", ..) {
      found_rename1 = true
    }
  }
  assert_true(found_rename1)
  assert_eq(b1.manifest.delta_payload_bytes, 0L)

  // Case 2: among multiple absent old paths, pick lowest sorted path.
  let old2 : Array[@manifest.DirFileEntry] = [
    { path: "b_gone.dat", bytes: shared, },
    { path: "a_gone.dat", bytes: shared, },
  ]
  let new2 : Array[@manifest.DirFileEntry] = [
    { path: "target.dat", bytes: shared, },
  ]
  let b2 = @manifest.dir_diff(old2, new2, @moonbsdiff.Limits::for_diff()).unwrap()
  let mut found_rename2 = false
  for e in b2.manifest.entries {
    if e is @manifest.Renamed(path="target.dat", from_path="a_gone.dat", ..) {
      found_rename2 = true
    }
  }
  assert_true(found_rename2)
  assert_eq(b2.manifest.delta_payload_bytes, 0L)
}

///|
test "dir bundle signed update key rotation tampering and cross-domain replay" {
  let sk1 = @manifest.PrivateKey::from_seed(
    dir_test_from_hex(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    ),
  ).unwrap()
  let sk2 = @manifest.PrivateKey::from_seed(
    dir_test_from_hex(
      "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
    ),
  ).unwrap()
  let sk3 = @manifest.PrivateKey::from_seed(
    dir_test_from_hex(
      "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
    ),
  ).unwrap()
  let pk1 = sk1.public_key()
  let pk2 = sk2.public_key()
  let pk3 = sk3.public_key()

  let app_old = dir_test_pattern_bytes(2048, 101)
  let app_new = dir_test_patch_slice(app_old, 512, b"signed-update-delta")
  let old_entries : Array[@manifest.DirFileEntry] = [
    { path: "bin/service", bytes: app_old, },
    { path: "README.txt", bytes: b"hello", },
  ]
  let new_entries : Array[@manifest.DirFileEntry] = [
    { path: "bin/service", bytes: app_new, },
    { path: "README.txt", bytes: b"hello", },
    { path: "notes.txt", bytes: b"added file", },
  ]
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let bundle = @manifest.dir_diff(old_entries, new_entries, diff_limits).unwrap()
  let blobs = dir_test_blobs_to_array(bundle.blobs)

  // Sign with rotated key sk2 and verify JSON round-trip.
  let sig = sk2.sign_dir_manifest(bundle.manifest_bytes).unwrap()
  assert_eq(sig.key_id(), pk2.key_id())
  assert_eq(sig.signature_bytes().length(), 64)
  assert_eq(sig.signature_hex().length(), 128)
  let sig_json = sig.to_json_bytes()
  let parsed_sig = @manifest.DirManifestSignature::from_json_bytes(sig_json).unwrap()
  assert_eq(parsed_sig, sig)

  // Single-key and multi-key rotation verification (including duplicate key deduplication).
  assert_eq(
    @manifest.verify_dir_manifest_signature(bundle.manifest_bytes, sig, pk2),
    Ok(()),
  )
  assert_eq(
    @manifest.verify_dir_manifest_signature_with_keys(
      bundle.manifest_bytes,
      sig,
      [pk1, pk2],
    ),
    Ok(pk2),
  )
  assert_eq(
    @manifest.verify_dir_manifest_signature_with_keys(
      bundle.manifest_bytes,
      sig,
      [pk1, pk2, pk1, pk2],
    ),
    Ok(pk2),
  )

  // Full signed apply with key rotation.
  let (restored, summary, signer_pk) = @manifest.dir_apply_signed(
    old_entries,
    bundle.manifest_bytes,
    parsed_sig,
    [pk1, pk2],
    blobs,
    apply_limits,
  ).unwrap()
  assert_eq(signer_pk, pk2)
  assert_eq(summary.patched_count, 1)
  assert_eq(summary.unchanged_count, 1)
  assert_eq(summary.added_count, 1)
  assert_eq(@manifest.tree_sha256(restored), @manifest.tree_sha256(new_entries))

  // 1. Untrusted key rejected (with deduplicated expected key_ids in KeyIdMismatch).
  let untrusted_sig = sk3.sign_dir_manifest(bundle.manifest_bytes).unwrap()
  assert_eq(
    @manifest.verify_dir_manifest_signature_with_keys(
      bundle.manifest_bytes,
      untrusted_sig,
      [pk1, pk2, pk1, pk2],
    ),
    Err(
      @manifest.KeyIdMismatch(
        expected=pk1.key_id() + "," + pk2.key_id(),
        actual=pk3.key_id(),
      ),
    ),
  )
  match
    @manifest.dir_apply_signed(
      old_entries,
      bundle.manifest_bytes,
      untrusted_sig,
      [pk1, pk2],
      blobs,
      apply_limits,
    ) {
    Err(@manifest.Signature(@manifest.KeyIdMismatch(actual~, ..))) =>
      assert_eq(actual, pk3.key_id())
    other => abort("expected KeyIdMismatch, got \{@debug.to_string(other)}")
  }

  // 2. Empty trusted key list rejected.
  match
    @manifest.dir_apply_signed(
      old_entries,
      bundle.manifest_bytes,
      sig,
      [],
      blobs,
      apply_limits,
    ) {
    Err(@manifest.Signature(@manifest.InvalidPublicKey(..))) => ()
    other => abort("expected InvalidPublicKey, got \{@debug.to_string(other)}")
  }

  // 3. Tampered manifest rejected BEFORE JSON parsing.
  match
    @manifest.dir_apply_signed(
      old_entries,
      b"{not even json",
      sig,
      [pk1, pk2],
      blobs,
      apply_limits,
    ) {
    Err(@manifest.Signature(@manifest.ManifestHashMismatch(..))) => ()
    other =>
      abort("expected ManifestHashMismatch, got \{@debug.to_string(other)}")
  }

  // 4. Forged signature (valid R/S from signing a different dir manifest, repacked with matching hash).
  let other_bundle = @manifest.dir_diff([], [], diff_limits).unwrap()
  let other_sig = sk2.sign_dir_manifest(other_bundle.manifest_bytes).unwrap()
  let forged_sig_json = dir_test_utf8_decode(sig_json).replace(
    old=sig.signature_hex(),
    new=other_sig.signature_hex(),
  )
  let forged_sig = @manifest.DirManifestSignature::from_json_bytes(
    @utf8.encode(forged_sig_json[:]),
  ).unwrap()
  assert_eq(
    @manifest.dir_apply_signed(
      old_entries,
      bundle.manifest_bytes,
      forged_sig,
      [pk1, pk2],
      blobs,
      apply_limits,
    ),
    Err(@manifest.Signature(@manifest.VerificationFailed)),
  )

  // 5. Cross-domain signature replay: single-file ManifestSignature rejected both structurally and cryptographically!
  let single_file_sig = sk2.sign_manifest(bundle.manifest_bytes).unwrap()
  match
    @manifest.DirManifestSignature::from_json_bytes(
      single_file_sig.to_json_bytes(),
    ) {
    Err(@manifest.InvalidSchema(..)) => ()
    other =>
      abort(
        "expected InvalidSchema when parsing single-file signature as dir sig, got \{@debug.to_string(other)}",
      )
  }
  // Repack raw 64-byte single-file Ed25519 signature bytes into DirManifestSignature envelope.
  let replayed_sig_json = dir_test_utf8_decode(sig_json).replace(
    old=sig.signature_hex(),
    new=single_file_sig.signature_hex(),
  )
  let replayed_sig = @manifest.DirManifestSignature::from_json_bytes(
    @utf8.encode(replayed_sig_json[:]),
  ).unwrap()
  assert_eq(
    @manifest.verify_dir_manifest_signature(
      bundle.manifest_bytes,
      replayed_sig,
      pk2,
    ),
    Err(@manifest.VerificationFailed),
  )
  assert_eq(
    @manifest.dir_apply_signed(
      old_entries,
      bundle.manifest_bytes,
      replayed_sig,
      [pk1, pk2],
      blobs,
      apply_limits,
    ),
    Err(@manifest.Signature(@manifest.VerificationFailed)),
  )

  // 5b. Cross-domain signature replay between CatalogSignature and DirManifestSignature
  // (closes the 3-way domain separation matrix: Manifest <-> Catalog <-> DirManifest).
  let sample_catalog = @manifest.ReleaseCatalog::new(
    "stable",
    1L,
    1L,
    [
      {
        version: 1L,
        label: "1.0.0",
        content: @manifest.ContentIdentity::of_bytes(b"v1"),
      },
    ],
    [],
  ).unwrap()
  let cat_bytes = sample_catalog.to_json_bytes()
  let cat_sig = sk2.sign_catalog(cat_bytes).unwrap()
  // Envelope cross-parse rejected in both directions.
  match
    @manifest.DirManifestSignature::from_json_bytes(cat_sig.to_json_bytes()) {
    Err(@manifest.InvalidSchema(..)) => ()
    other =>
      abort(
        "expected InvalidSchema when parsing CatalogSignature as DirManifestSignature, got \{@debug.to_string(other)}",
      )
  }
  match @manifest.CatalogSignature::from_json_bytes(sig.to_json_bytes()) {
    Err(@manifest.InvalidSchema(..)) => ()
    other =>
      abort(
        "expected InvalidSchema when parsing DirManifestSignature as CatalogSignature, got \{@debug.to_string(other)}",
      )
  }
  // CatalogSignature -> DirManifestSignature cryptographic replay rejected.
  let cat_as_dir_json = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest-signature\",\"algorithm\":\"ed25519\"," +
    "\"key_id\":\"\{cat_sig.key_id()}\"," +
    "\"dir_manifest_sha256\":\"\{cat_sig.catalog_sha256()}\"," +
    "\"signature\":\"\{cat_sig.signature_hex()}\"}\n")[:],
  )
  let cat_as_dir_sig = @manifest.DirManifestSignature::from_json_bytes(
    cat_as_dir_json,
  ).unwrap()
  assert_eq(
    @manifest.verify_dir_manifest_signature(cat_bytes, cat_as_dir_sig, pk2),
    Err(@manifest.VerificationFailed),
  )
  assert_eq(
    @manifest.verify_dir_manifest_signature_with_keys(
      cat_bytes,
      cat_as_dir_sig,
      [pk1, pk2],
    ),
    Err(@manifest.VerificationFailed),
  )
  // DirManifestSignature -> CatalogSignature cryptographic replay rejected.
  let dir_as_cat_json = @utf8.encode(
    ("{\"schema_version\":1,\"format\":\"moonbsdiff-catalog-signature\",\"algorithm\":\"ed25519\"," +
    "\"key_id\":\"\{sig.key_id()}\"," +
    "\"catalog_sha256\":\"\{sig.dir_manifest_sha256()}\"," +
    "\"signature\":\"\{sig.signature_hex()}\"}\n")[:],
  )
  let dir_as_cat_sig = @manifest.CatalogSignature::from_json_bytes(
    dir_as_cat_json,
  ).unwrap()
  let trust_store = @manifest.TrustStore::from_keys([pk1, pk2]).unwrap()
  assert_eq(
    trust_store.verify_catalog(bundle.manifest_bytes, dir_as_cat_sig),
    Err(@manifest.CatalogError::Signature(@manifest.VerificationFailed)),
  )

  // 6. Tampered patch blob rejected with IdentityMismatch(Patch, Sha256).
  let tampered_patch_blobs : Array[@manifest.DirBlob] = []
  for blob in blobs {
    if blob.name.has_suffix(".patch") {
      let mutated = dir_test_patch_slice(blob.bytes, 0, b"X")
      tampered_patch_blobs.push({ name: blob.name, bytes: mutated, })
    } else {
      tampered_patch_blobs.push(blob)
    }
  }
  match
    @manifest.dir_apply_signed(
      old_entries,
      bundle.manifest_bytes,
      sig,
      [pk1, pk2],
      tampered_patch_blobs,
      apply_limits,
    ) {
    Err(
      @manifest.IdentityMismatch(
        path="bin/service",
        object=@manifest.Patch,
        difference=@manifest.Sha256,
      ),
    ) => ()
    other =>
      abort(
        "expected IdentityMismatch(Patch, Sha256), got \{@debug.to_string(other)}",
      )
  }

  // 7. Tampered full blob rejected with IdentityMismatch(Restored, Sha256).
  let tampered_full_blobs : Array[@manifest.DirBlob] = []
  for blob in blobs {
    if blob.name.has_suffix(".full") {
      let mutated = dir_test_patch_slice(blob.bytes, 0, b"Z")
      tampered_full_blobs.push({ name: blob.name, bytes: mutated, })
    } else {
      tampered_full_blobs.push(blob)
    }
  }
  match
    @manifest.dir_apply_signed(
      old_entries,
      bundle.manifest_bytes,
      sig,
      [pk1, pk2],
      tampered_full_blobs,
      apply_limits,
    ) {
    Err(
      @manifest.IdentityMismatch(
        path="notes.txt",
        object=@manifest.Restored,
        difference=@manifest.Sha256,
      ),
    ) => ()
    other =>
      abort(
        "expected IdentityMismatch(Restored, Sha256), got \{@debug.to_string(other)}",
      )
  }

  // 8. Extra unreferenced blob rejected fail-closed.
  let extra_blobs = blobs.copy()
  extra_blobs.push({ name: "blob-9999.full", bytes: b"unreferenced", })
  assert_eq(
    @manifest.dir_apply_signed(
      old_entries,
      bundle.manifest_bytes,
      sig,
      [pk1, pk2],
      extra_blobs,
      apply_limits,
    ),
    Err(@manifest.UnexpectedBlob("blob-9999.full")),
  )

  // 9. Duplicate blob name rejected.
  let dup_blobs = blobs.copy()
  dup_blobs.push(blobs[0])
  assert_eq(
    @manifest.dir_apply(
      old_entries,
      bundle.manifest_bytes,
      dup_blobs,
      apply_limits,
    ),
    Err(@manifest.DuplicateBlob(blobs[0].name)),
  )

  // 10. Missing referenced blob rejected.
  assert_eq(
    @manifest.dir_apply(
      old_entries,
      bundle.manifest_bytes,
      [blobs[0]],
      apply_limits,
    ),
    Err(@manifest.MissingBlob(blobs[1].name)),
  )

  // 11. Wrong old tree rejected BEFORE applying.
  let wrong_old : Array[@manifest.DirFileEntry] = [
    { path: "bin/service", bytes: app_old, },
    { path: "README.txt", bytes: b"tampered", },
  ]
  match
    @manifest.dir_apply_signed(
      wrong_old,
      bundle.manifest_bytes,
      sig,
      [pk1, pk2],
      blobs,
      apply_limits,
    ) {
    Err(@manifest.OldTreeMismatch(..)) => ()
    other => abort("expected OldTreeMismatch, got \{@debug.to_string(other)}")
  }

  // 12. sign_dir_manifest validates manifest schema BEFORE signing.
  match sk2.sign_dir_manifest(b"{\"schema\":1,\"type\":\"wrong\"}") {
    Err(@manifest.InvalidSchema(..)) => ()
    other =>
      abort(
        "expected sign_dir_manifest to reject invalid manifest, got \{@debug.to_string(other)}",
      )
  }
}

///|
test "dir bundle manifest schema security and unsafe blob_name rejection" {
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let old_entries : Array[@manifest.DirFileEntry] = []
  let new_entries : Array[@manifest.DirFileEntry] = [
    { path: "hello.txt", bytes: b"world", },
  ]
  let bundle = @manifest.dir_diff(old_entries, new_entries, diff_limits).unwrap()
  let valid_json = dir_test_utf8_decode(bundle.manifest_bytes)

  // Unsafe blob_names in manifest JSON must be rejected.
  let unsafe_blob_names = [
    "../evil.patch", ".hidden", "dir/blob.full", "a..b.full", "bad name.full", "",
  ]
  for bad_name in unsafe_blob_names {
    let mutated = valid_json.replace(old="blob-0001.full", new=bad_name)
    match @manifest.DirManifest::from_json_bytes(@utf8.encode(mutated[:])) {
      Err(@manifest.InvalidBlobName(..)) => ()
      other =>
        abort(
          "expected InvalidBlobName for \{bad_name}, got \{@debug.to_string(other)}",
        )
    }
  }

  // Unsafe blob_name in blobs argument to dir_apply must be rejected.
  match
    @manifest.dir_apply(
      old_entries,
      bundle.manifest_bytes,
      [{ name: "../evil.patch", bytes: b"world", }],
      apply_limits,
    ) {
    Err(@manifest.InvalidBlobName(..)) => ()
    other =>
      abort(
        "expected InvalidBlobName in dir_apply, got \{@debug.to_string(other)}",
      )
  }

  // Unsafe path in manifest JSON must be rejected.
  let bad_path_json = valid_json.replace(old="hello.txt", new="../escape")
  match @manifest.DirManifest::from_json_bytes(@utf8.encode(bad_path_json[:])) {
    Err(@manifest.InvalidPath(..)) => ()
    other =>
      abort(
        "expected InvalidPath in manifest JSON, got \{@debug.to_string(other)}",
      )
  }

  // Unknown key rejected.
  let unknown_key_json = valid_json.replace(
    old="\"schema\":1,",
    new="\"schema\":1,\"extra\":true,",
  )
  match
    @manifest.DirManifest::from_json_bytes(@utf8.encode(unknown_key_json[:])) {
    Err(@manifest.InvalidSchema(field="extra", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for unknown key, got \{@debug.to_string(other)}",
      )
  }

  // Duplicate JSON key rejected.
  let dup_key_json = valid_json.replace(
    old="\"schema\":1,",
    new="\"schema\":1,\"schema\":1,",
  )
  match @manifest.DirManifest::from_json_bytes(@utf8.encode(dup_key_json[:])) {
    Err(@manifest.InvalidJson(field=Some("schema"), ..)) => ()
    other =>
      abort(
        "expected InvalidJson for duplicate key, got \{@debug.to_string(other)}",
      )
  }

  // UTF-8 BOM rejected.
  assert_eq(
    @manifest.DirManifest::from_json_bytes(
      b"\xef\xbb\xbf" + bundle.manifest_bytes,
    ),
    Err(@manifest.InvalidEncoding),
  )

  // Wrong schema version and wrong type rejected.
  let bad_schema = valid_json.replace(old="\"schema\":1,", new="\"schema\":2,")
  match @manifest.DirManifest::from_json_bytes(@utf8.encode(bad_schema[:])) {
    Err(@manifest.InvalidSchema(field="schema", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for schema=2, got \{@debug.to_string(other)}",
      )
  }
  let bad_type = valid_json.replace(
    old="moonbsdiff-dir-manifest",
    new="moonbsdiff-manifest",
  )
  match @manifest.DirManifest::from_json_bytes(@utf8.encode(bad_type[:])) {
    Err(@manifest.InvalidSchema(field="type", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for bad type, got \{@debug.to_string(other)}",
      )
  }

  // Tampered new_tree_sha256 rejected as inconsistent schema.
  let bad_hash = valid_json.replace(
    old=bundle.manifest.new_tree_sha256,
    new="0000000000000000000000000000000000000000000000000000000000000000",
  )
  match @manifest.DirManifest::from_json_bytes(@utf8.encode(bad_hash[:])) {
    Err(@manifest.InvalidSchema(field="new_tree_sha256", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for inconsistent new_tree_sha256, got \{@debug.to_string(other)}",
      )
  }

  // Oversized manifest rejected (> max_dir_manifest_bytes = 524288).
  let oversized = Bytes::make(@manifest.max_dir_manifest_bytes + 1, b' ')
  assert_eq(
    @manifest.DirManifest::from_json_bytes(oversized),
    Err(
      @manifest.LimitExceeded(
        field="max_dir_manifest_bytes",
        value=(@manifest.max_dir_manifest_bytes + 1).to_int64(),
        limit=@manifest.max_dir_manifest_bytes.to_int64(),
      ),
    ),
  )

  // File/dir prefix collision inside manifest entries rejected.
  let id_file = @manifest.ContentIdentity::of_bytes(b"a")
  let empty_tree = @manifest.tree_sha256([]).unwrap()
  let collision_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{empty_tree}\"," +
    "\"new_tree_sha256\":\"\{empty_tree}\"," +
    "\"old_file_count\":0,\"new_file_count\":2," +
    "\"old_total_bytes\":\"0\",\"new_total_bytes\":\"2\",\"delta_payload_bytes\":\"2\"," +
    "\"entries\":[" +
    "{\"action\":\"added\",\"path\":\"a\",\"identity\":{\"size_bytes\":\"1\",\"sha256\":\"\{id_file.hash}\"},\"blob_name\":\"blob-0001.full\",\"full_fallback\":false}," +
    "{\"action\":\"added\",\"path\":\"a/b\",\"identity\":{\"size_bytes\":\"1\",\"sha256\":\"\{id_file.hash}\"},\"blob_name\":\"blob-0002.full\",\"full_fallback\":false}" +
    "]}\n")[:],
  )
  assert_eq(
    @manifest.DirManifest::from_json_bytes(collision_manifest),
    Err(@manifest.PathCollision(a="a", b="a/b")),
  )
}

///|
test "dir bundle empty directories empty files and resource limits" {
  let diff_limits = @moonbsdiff.Limits::for_diff()
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  // 1. empty -> empty
  let b_ee = @manifest.dir_diff([], [], diff_limits).unwrap()
  assert_eq(b_ee.manifest.old_tree_sha256, empty_hash)
  assert_eq(b_ee.manifest.new_tree_sha256, empty_hash)
  assert_eq(b_ee.manifest.old_file_count, 0)
  assert_eq(b_ee.manifest.new_file_count, 0)
  assert_eq(b_ee.manifest.delta_payload_bytes, 0L)
  assert_eq(b_ee.blobs.length(), 0)
  let (restored_ee, sum_ee) = @manifest.dir_apply(
    [],
    b_ee.manifest_bytes,
    [],
    apply_limits,
  ).unwrap()
  assert_eq(restored_ee, [])
  assert_eq(sum_ee.unchanged_count, 0)
  assert_eq(sum_ee.added_count, 0)
  assert_eq(sum_ee.deleted_count, 0)

  // 2. empty -> non-empty (including a 0-byte file)
  let non_empty : Array[@manifest.DirFileEntry] = [
    { path: "a/empty.bin", bytes: b"", },
    { path: "b/data.txt", bytes: b"fresh directory payload", },
  ]
  let b_en = @manifest.dir_diff([], non_empty, diff_limits).unwrap()
  let sum_en = @manifest.dir_summarize(b_en.manifest)
  assert_eq(sum_en.added_count, 2)
  assert_eq(sum_en.full_fallback_count, 0)
  assert_eq(sum_en.deleted_count, 0)
  assert_eq(b_en.blobs.length(), 2)
  let (restored_en, _) = @manifest.dir_apply(
    [],
    b_en.manifest_bytes,
    dir_test_blobs_to_array(b_en.blobs),
    apply_limits,
  ).unwrap()
  assert_eq(restored_en, non_empty)

  // 3. non-empty -> empty
  let b_ne = @manifest.dir_diff(non_empty, [], diff_limits).unwrap()
  let sum_ne = @manifest.dir_summarize(b_ne.manifest)
  assert_eq(sum_ne.deleted_count, 2)
  assert_eq(sum_ne.added_count, 0)
  assert_eq(b_ne.manifest.delta_payload_bytes, 0L)
  assert_eq(b_ne.blobs.length(), 0)
  let (restored_ne, _) = @manifest.dir_apply(
    non_empty,
    b_ne.manifest_bytes,
    [],
    apply_limits,
  ).unwrap()
  assert_eq(restored_ne, [])

  // 4. Limits enforcement: invalid limits, max_output_bytes in diff and apply, fallback when diff budget exhausted.
  let bad_limits = { ..diff_limits, max_output_bytes: 0L, }
  match @manifest.dir_diff([], non_empty, bad_limits) {
    Err(@manifest.InvalidLimits(_)) => ()
    other => abort("expected InvalidLimits, got \{@debug.to_string(other)}")
  }
  match @manifest.dir_apply([], b_ee.manifest_bytes, [], bad_limits) {
    Err(@manifest.InvalidLimits(_)) => ()
    other =>
      abort("expected InvalidLimits in apply, got \{@debug.to_string(other)}")
  }
  let tiny_out = { ..diff_limits, max_output_bytes: 4L, }
  assert_eq(
    @manifest.dir_diff([], non_empty, tiny_out),
    Err(@manifest.LimitExceeded(field="max_output_bytes", value=23L, limit=4L)),
  )
  let tiny_apply = { ..apply_limits, max_output_bytes: 4L, }
  assert_eq(
    @manifest.dir_apply(
      [],
      b_en.manifest_bytes,
      dir_test_blobs_to_array(b_en.blobs),
      tiny_apply,
    ),
    Err(@manifest.LimitExceeded(field="max_output_bytes", value=23L, limit=4L)),
  )

  // max_new_bytes < new_size <= max_output_bytes must be rejected in dir_diff
  // for BOTH brand-new files and modified files (never swallowed into full_fallback).
  let tiny_new = { ..diff_limits, max_new_bytes: 4L, max_output_bytes: 2048L, }
  assert_eq(
    @manifest.dir_diff([], non_empty, tiny_new),
    Err(@manifest.LimitExceeded(field="max_new_bytes", value=23L, limit=4L)),
  )
  let tiny_new_apply = {
    ..apply_limits,
    max_new_bytes: 4L,
    max_output_bytes: 2048L,
  }
  assert_eq(
    @manifest.dir_apply(
      [],
      b_en.manifest_bytes,
      dir_test_blobs_to_array(b_en.blobs),
      tiny_new_apply,
    ),
    Err(@manifest.LimitExceeded(field="max_new_bytes", value=23L, limit=4L)),
  )
  let mod_old = dir_test_pattern_bytes(64, 19)
  let mod_new = dir_test_patch_slice(mod_old, 10, b"modified-payload")
  let tiny_new_fallback = {
    ..diff_limits,
    max_new_bytes: 32L,
    max_output_bytes: 2048L,
    max_sort_work: 1L,
  }
  assert_eq(
    @manifest.dir_diff(
      [{ path: "mod.bin", bytes: mod_old, }],
      [{ path: "mod.bin", bytes: mod_new, }],
      tiny_new_fallback,
    ),
    Err(@manifest.LimitExceeded(field="max_new_bytes", value=64L, limit=32L)),
  )

  // Diff work budget too small on a modified file gracefully falls back to Added(full_fallback=true).
  let big_old = dir_test_pattern_bytes(1024, 5)
  let big_new = dir_test_patch_slice(big_old, 100, b"changed")
  let tight_sort = { ..diff_limits, max_sort_work: 1L, }
  let fb_bundle = @manifest.dir_diff(
    [{ path: "f.bin", bytes: big_old, }],
    [{ path: "f.bin", bytes: big_new, }],
    tight_sort,
  ).unwrap()
  let fb_sum = @manifest.dir_summarize(fb_bundle.manifest)
  assert_eq(fb_sum.patched_count, 0)
  assert_eq(fb_sum.added_count, 1)
  assert_eq(fb_sum.full_fallback_count, 1)
  let (fb_restored, _) = @manifest.dir_apply(
    [{ path: "f.bin", bytes: big_old, }],
    fb_bundle.manifest_bytes,
    dir_test_blobs_to_array(fb_bundle.blobs),
    apply_limits,
  ).unwrap()
  assert_eq(fb_restored, [{ path: "f.bin", bytes: big_new, }])

  // Unchanged and Renamed entries must enforce max_old_bytes / max_new_bytes / max_output_bytes
  // in BOTH dir_diff and dir_apply.
  let payload_1k = dir_test_pattern_bytes(1024, 33)
  let unchanged_old : Array[@manifest.DirFileEntry] = [
    { path: "a.bin", bytes: payload_1k, },
  ]
  let renamed_new : Array[@manifest.DirFileEntry] = [
    { path: "b.bin", bytes: payload_1k, },
  ]
  let ok_unchanged = @manifest.dir_diff(
    unchanged_old, unchanged_old, diff_limits,
  ).unwrap()
  let ok_renamed = @manifest.dir_diff(unchanged_old, renamed_new, diff_limits).unwrap()
  for
    (bad_lim, field) in [
      ({ ..diff_limits, max_old_bytes: 512L, }, "max_old_bytes"),
      ({ ..diff_limits, max_new_bytes: 512L, }, "max_new_bytes"),
      ({ ..diff_limits, max_output_bytes: 512L, }, "max_output_bytes"),
    ] {
    assert_eq(
      @manifest.dir_diff(unchanged_old, unchanged_old, bad_lim),
      Err(@manifest.LimitExceeded(field~, value=1024L, limit=512L)),
    )
    assert_eq(
      @manifest.dir_diff(unchanged_old, renamed_new, bad_lim),
      Err(@manifest.LimitExceeded(field~, value=1024L, limit=512L)),
    )
    assert_eq(
      @manifest.dir_apply(
        unchanged_old,
        ok_unchanged.manifest_bytes,
        [],
        bad_lim,
      ),
      Err(@manifest.LimitExceeded(field~, value=1024L, limit=512L)),
    )
    assert_eq(
      @manifest.dir_apply(unchanged_old, ok_renamed.manifest_bytes, [], bad_lim),
      Err(@manifest.LimitExceeded(field~, value=1024L, limit=512L)),
    )
  }

  // Renamed fan-out cloning bomb (1 Unchanged + 32 Renamed of same 1 KiB old file,
  // 0 blobs) must be rejected by dir_apply under max_output_bytes = 4096L.
  let clone_id = @manifest.ContentIdentity::of_bytes(payload_1k)
  let clone_old_tree = @manifest.tree_sha256(unchanged_old).unwrap()
  let clone_new_entries : Array[@manifest.DirFileEntry] = [
    { path: "a.bin", bytes: payload_1k, },
  ]
  let clone_json = StringBuilder()
  clone_json.write_string(
    "{\"action\":\"unchanged\",\"path\":\"a.bin\",\"identity\":{\"size_bytes\":\"1024\",\"sha256\":\"\{clone_id.hash}\"}}",
  )
  for i = 0; i < 32; i = i + 1 {
    let p = "clone-\{i}.bin"
    clone_new_entries.push({ path: p, bytes: payload_1k, })
    clone_json.write_string(
      ",{\"action\":\"renamed\",\"path\":\"\{p}\",\"from_path\":\"a.bin\",\"identity\":{\"size_bytes\":\"1024\",\"sha256\":\"\{clone_id.hash}\"}}",
    )
  }
  let clone_new_tree = @manifest.tree_sha256(clone_new_entries).unwrap()
  let clone_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{clone_old_tree}\"," +
    "\"new_tree_sha256\":\"\{clone_new_tree}\"," +
    "\"old_file_count\":1,\"new_file_count\":33," +
    "\"old_total_bytes\":\"1024\",\"new_total_bytes\":\"33792\",\"delta_payload_bytes\":\"0\"," +
    "\"entries\":[" +
    clone_json.to_string() +
    "]}\n")[:],
  )
  let clone_limits = { ..apply_limits, max_output_bytes: 4096L, }
  assert_eq(
    @manifest.dir_apply(unchanged_old, clone_manifest, [], clone_limits),
    Err(
      @manifest.LimitExceeded(
        field="max_output_bytes",
        value=5120L,
        limit=4096L,
      ),
    ),
  )

  // dir_diff caps Renamed clones to <= max_output_bytes and falls back to Added
  // so dir_diff -> dir_apply stays consistent under the exact same Limits.
  let many_copies_new : Array[@manifest.DirFileEntry] = [
    { path: "a.bin", bytes: payload_1k, },
  ]
  for i = 0; i < 8; i = i + 1 {
    many_copies_new.push({ path: "copy-\{i}.bin", bytes: payload_1k, })
  }
  let capped_limits = { ..diff_limits, max_output_bytes: 4096L, }
  let capped_bundle = @manifest.dir_diff(
    unchanged_old, many_copies_new, capped_limits,
  ).unwrap()
  let capped_sum = @manifest.dir_summarize(capped_bundle.manifest)
  assert_eq(capped_sum.unchanged_count, 1)
  assert_eq(capped_sum.renamed_count, 4)
  assert_eq(capped_sum.added_count, 4)
  let (capped_restored, _) = @manifest.dir_apply(
    unchanged_old,
    capped_bundle.manifest_bytes,
    dir_test_blobs_to_array(capped_bundle.blobs),
    capped_limits,
  ).unwrap()
  assert_eq(
    @manifest.tree_sha256(capped_restored),
    @manifest.tree_sha256(many_copies_new),
  )

  // Duplicate Patched from_path fan-out bombs (#59 64 KiB zero-fill PoC and
  // #63 1-byte control-tuple fan-out PoC) must be rejected upfront by
  // DirManifest::from_json_bytes, PrivateKey::sign_dir_manifest, and dir_apply.
  let fanout_sk = @manifest.PrivateKey::from_seed(
    dir_test_from_hex(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    ),
  ).unwrap()
  let old_zero : Array[@manifest.DirFileEntry] = [{ path: "a", bytes: b"", }]
  let old_zero_id = @manifest.ContentIdentity::of_bytes(b"")
  let old_zero_tree = @manifest.tree_sha256(old_zero).unwrap()
  let target_64k = Bytes::make(65536, b'\x00')
  let target_64k_id = @manifest.ContentIdentity::of_bytes(target_64k)
  let fanout_limits = {
    ..apply_limits,
    max_old_bytes: 65536L,
    max_new_bytes: 65536L,
    max_output_bytes: 65536L,
    max_decompressed_bytes: 131072L,
  }
  let zero_fill_patch = @moonbsdiff.diff(b"", target_64k, {
    ..diff_limits,
    max_old_bytes: 65536L,
    max_new_bytes: 65536L,
    max_output_bytes: 65536L,
  }).unwrap()
  let zero_fill_patch_id = @manifest.ContentIdentity::of_bytes(zero_fill_patch)
  let fanout_count = 16
  let fanout_new_entries : Array[@manifest.DirFileEntry] = []
  let fanout_blobs : Array[@manifest.DirBlob] = []
  let fanout_entries_json = StringBuilder()
  for i = 0; i < fanout_count; i = i + 1 {
    let p = "f\{i}"
    let bname = "blob-\{i}.patch"
    fanout_new_entries.push({ path: p, bytes: target_64k, })
    fanout_blobs.push({ name: bname, bytes: zero_fill_patch, })
    if i > 0 {
      fanout_entries_json.write_string(",")
    }
    fanout_entries_json.write_string(
      "{\"action\":\"patched\",\"path\":\"\{p}\",\"from_path\":\"a\"," +
      "\"old_identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"}," +
      "\"new_identity\":{\"size_bytes\":\"65536\",\"sha256\":\"\{target_64k_id.hash}\"}," +
      "\"patch_identity\":{\"size_bytes\":\"\{zero_fill_patch_id.size}\",\"sha256\":\"\{zero_fill_patch_id.hash}\"}," +
      "\"blob_name\":\"\{bname}\"}",
    )
  }
  let fanout_new_tree = @manifest.tree_sha256(fanout_new_entries).unwrap()
  let fanout_delta_total = zero_fill_patch_id.size * fanout_count.to_int64()
  let fanout_new_total = 65536L * fanout_count.to_int64()
  let fanout_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{old_zero_tree}\"," +
    "\"new_tree_sha256\":\"\{fanout_new_tree}\"," +
    "\"old_file_count\":1,\"new_file_count\":\{fanout_count}," +
    "\"old_total_bytes\":\"0\",\"new_total_bytes\":\"\{fanout_new_total}\"," +
    "\"delta_payload_bytes\":\"\{fanout_delta_total}\"," +
    "\"entries\":[" +
    fanout_entries_json.to_string() +
    "]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(fanout_manifest) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema(entries) for 64 KiB Patched fan-out, got \{@debug.to_string(other)}",
      )
  }
  match fanout_sk.sign_dir_manifest(fanout_manifest) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected sign_dir_manifest to reject 64 KiB Patched fan-out, got \{@debug.to_string(other)}",
      )
  }
  match
    @manifest.dir_apply(old_zero, fanout_manifest, fanout_blobs, fanout_limits) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected dir_apply to reject 64 KiB Patched fan-out, got \{@debug.to_string(other)}",
      )
  }

  // #63 1-byte Patched(from_path="a") bzip2 control-tuple fan-out PoC: even
  // when each output is only 1 byte (well below max_output_bytes), duplicate
  // Patched from_path is rejected upfront at parse, sign, and apply time.
  let one_byte = b"\x00"
  let one_byte_id = @manifest.ContentIdentity::of_bytes(one_byte)
  let one_byte_patch = @moonbsdiff.diff(b"", one_byte, diff_limits).unwrap()
  let one_byte_patch_id = @manifest.ContentIdentity::of_bytes(one_byte_patch)
  let tiny_fanout_count = 32
  let tiny_fanout_new : Array[@manifest.DirFileEntry] = []
  let tiny_fanout_blobs : Array[@manifest.DirBlob] = []
  let tiny_fanout_json = StringBuilder()
  for i = 0; i < tiny_fanout_count; i = i + 1 {
    let p = "t\{i}"
    let bname = "tiny-\{i}.patch"
    tiny_fanout_new.push({ path: p, bytes: one_byte, })
    tiny_fanout_blobs.push({ name: bname, bytes: one_byte_patch, })
    if i > 0 {
      tiny_fanout_json.write_string(",")
    }
    tiny_fanout_json.write_string(
      "{\"action\":\"patched\",\"path\":\"\{p}\",\"from_path\":\"a\"," +
      "\"old_identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"}," +
      "\"new_identity\":{\"size_bytes\":\"1\",\"sha256\":\"\{one_byte_id.hash}\"}," +
      "\"patch_identity\":{\"size_bytes\":\"\{one_byte_patch_id.size}\",\"sha256\":\"\{one_byte_patch_id.hash}\"}," +
      "\"blob_name\":\"\{bname}\"}",
    )
  }
  let tiny_fanout_tree = @manifest.tree_sha256(tiny_fanout_new).unwrap()
  let tiny_fanout_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{old_zero_tree}\"," +
    "\"new_tree_sha256\":\"\{tiny_fanout_tree}\"," +
    "\"old_file_count\":1,\"new_file_count\":\{tiny_fanout_count}," +
    "\"old_total_bytes\":\"0\",\"new_total_bytes\":\"\{tiny_fanout_count}\"," +
    "\"delta_payload_bytes\":\"\{one_byte_patch_id.size * tiny_fanout_count.to_int64()}\"," +
    "\"entries\":[" +
    tiny_fanout_json.to_string() +
    "]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(tiny_fanout_manifest) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema(entries) for 1-byte Patched fan-out, got \{@debug.to_string(other)}",
      )
  }
  match fanout_sk.sign_dir_manifest(tiny_fanout_manifest) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected sign_dir_manifest to reject 1-byte Patched fan-out, got \{@debug.to_string(other)}",
      )
  }
  match
    @manifest.dir_apply(
      old_zero, tiny_fanout_manifest, tiny_fanout_blobs, apply_limits,
    ) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected dir_apply to reject 1-byte Patched fan-out, got \{@debug.to_string(other)}",
      )
  }

  // Distinct Patched from_paths placed BEFORE Unchanged still see their source
  // paths pre-claimed by Unchanged and hit LimitExceeded(max_output_bytes) when
  // cumulative cloned output exceeds limits.max_output_bytes.
  let old_ab_zero : Array[@manifest.DirFileEntry] = [
    { path: "a", bytes: b"", },
    { path: "b", bytes: b"", },
  ]
  let old_ab_zero_tree = @manifest.tree_sha256(old_ab_zero).unwrap()
  let up_entries : Array[@manifest.DirFileEntry] = [
    { path: "a", bytes: b"", },
    { path: "b", bytes: b"", },
    { path: "p0", bytes: target_64k, },
    { path: "p1", bytes: target_64k, },
  ]
  let up_new_tree = @manifest.tree_sha256(up_entries).unwrap()
  let up_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{old_ab_zero_tree}\"," +
    "\"new_tree_sha256\":\"\{up_new_tree}\"," +
    "\"old_file_count\":2,\"new_file_count\":4," +
    "\"old_total_bytes\":\"0\",\"new_total_bytes\":\"131072\"," +
    "\"delta_payload_bytes\":\"\{zero_fill_patch_id.size * 2L}\"," +
    "\"entries\":[" +
    "{\"action\":\"patched\",\"path\":\"p0\",\"from_path\":\"a\",\"old_identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"},\"new_identity\":{\"size_bytes\":\"65536\",\"sha256\":\"\{target_64k_id.hash}\"},\"patch_identity\":{\"size_bytes\":\"\{zero_fill_patch_id.size}\",\"sha256\":\"\{zero_fill_patch_id.hash}\"},\"blob_name\":\"p0.patch\"}," +
    "{\"action\":\"patched\",\"path\":\"p1\",\"from_path\":\"b\",\"old_identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"},\"new_identity\":{\"size_bytes\":\"65536\",\"sha256\":\"\{target_64k_id.hash}\"},\"patch_identity\":{\"size_bytes\":\"\{zero_fill_patch_id.size}\",\"sha256\":\"\{zero_fill_patch_id.hash}\"},\"blob_name\":\"p1.patch\"}," +
    "{\"action\":\"unchanged\",\"path\":\"a\",\"identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"}}," +
    "{\"action\":\"unchanged\",\"path\":\"b\",\"identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"}}" +
    "]}\n")[:],
  )
  assert_true(@manifest.DirManifest::from_json_bytes(up_manifest) is Ok(_))
  assert_eq(
    @manifest.dir_apply(
      old_ab_zero,
      up_manifest,
      [
        { name: "p0.patch", bytes: zero_fill_patch, },
        { name: "p1.patch", bytes: zero_fill_patch, },
      ],
      fanout_limits,
    ),
    Err(
      @manifest.LimitExceeded(
        field="max_output_bytes",
        value=131072L,
        limit=65536L,
      ),
    ),
  )

  // Legitimate single rename+modify (Patched(path="b", from_path="a") + Deleted("a"))
  // continues to parse and apply cleanly.
  let rename_mod_tree = @manifest.tree_sha256([
    { path: "b", bytes: target_64k, },
  ]).unwrap()
  let rename_mod_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{old_zero_tree}\"," +
    "\"new_tree_sha256\":\"\{rename_mod_tree}\"," +
    "\"old_file_count\":1,\"new_file_count\":1," +
    "\"old_total_bytes\":\"0\",\"new_total_bytes\":\"65536\"," +
    "\"delta_payload_bytes\":\"\{zero_fill_patch_id.size}\"," +
    "\"entries\":[" +
    "{\"action\":\"patched\",\"path\":\"b\",\"from_path\":\"a\",\"old_identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"},\"new_identity\":{\"size_bytes\":\"65536\",\"sha256\":\"\{target_64k_id.hash}\"},\"patch_identity\":{\"size_bytes\":\"\{zero_fill_patch_id.size}\",\"sha256\":\"\{zero_fill_patch_id.hash}\"},\"blob_name\":\"rm.patch\"}," +
    "{\"action\":\"deleted\",\"path\":\"a\",\"old_identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{old_zero_id.hash}\"}}" +
    "]}\n")[:],
  )
  let (rm_restored, _) = @manifest.dir_apply(
    old_zero,
    rename_mod_manifest,
    [{ name: "rm.patch", bytes: zero_fill_patch, }],
    fanout_limits,
  ).unwrap()
  assert_eq(rm_restored, [{ path: "b", bytes: target_64k, }])

  // dir_diff <-> dir_apply parity when Renamed + Patched reuse the same old
  // paths under a tight max_output_bytes budget: dir_diff falls back excess
  // Patched clones to Added(full_fallback=true) so dir_apply accepts the bundle.
  let old_x0 = dir_test_pattern_bytes(4096, 41)
  let old_x1 = dir_test_pattern_bytes(4096, 73)
  let new_y0 = dir_test_patch_slice(old_x0, 200, b"patched-y0")
  let new_y1 = dir_test_patch_slice(old_x1, 200, b"patched-y1")
  let mixed_old : Array[@manifest.DirFileEntry] = [
    { path: "a.bin", bytes: old_x0, },
    { path: "c.bin", bytes: old_x1, },
  ]
  let mixed_new : Array[@manifest.DirFileEntry] = [
    { path: "0.bin", bytes: old_x0, },
    { path: "1.bin", bytes: old_x1, },
    { path: "a.bin", bytes: new_y0, },
    { path: "c.bin", bytes: new_y1, },
  ]
  let mixed_limits = { ..diff_limits, max_output_bytes: 4096L, }
  let mixed_bundle = @manifest.dir_diff(mixed_old, mixed_new, mixed_limits).unwrap()
  let mixed_sum = @manifest.dir_summarize(mixed_bundle.manifest)
  assert_eq(mixed_sum.renamed_count, 2)
  assert_eq(mixed_sum.patched_count, 1)
  assert_eq(mixed_sum.full_fallback_count, 1)
  let (mixed_restored, _) = @manifest.dir_apply(
    mixed_old,
    mixed_bundle.manifest_bytes,
    dir_test_blobs_to_array(mixed_bundle.blobs),
    mixed_limits,
  ).unwrap()
  assert_eq(
    @manifest.tree_sha256(mixed_restored),
    @manifest.tree_sha256(mixed_new),
  )
}

///|
test "dir bundle signature envelope hardening and manifest edge invariants" {
  let sk = @manifest.PrivateKey::from_seed(
    dir_test_from_hex(
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    ),
  ).unwrap()
  let bundle = @manifest.dir_diff([], [], @moonbsdiff.Limits::for_diff()).unwrap()
  let sig = sk.sign_dir_manifest(bundle.manifest_bytes).unwrap()
  let sig_text = dir_test_utf8_decode(sig.to_json_bytes())

  // Oversized signature envelope (> 4096 bytes) rejected.
  let big_sig = Bytes::make(@manifest.max_signature_file_bytes + 1, b' ')
  assert_eq(
    @manifest.DirManifestSignature::from_json_bytes(big_sig),
    Err(
      @manifest.LimitExceeded(
        field="max_signature_file_bytes",
        value=(@manifest.max_signature_file_bytes + 1).to_int64(),
        limit=@manifest.max_signature_file_bytes.to_int64(),
      ),
    ),
  )

  // BOM, duplicate key, unknown key rejected on DirManifestSignature.
  assert_eq(
    @manifest.DirManifestSignature::from_json_bytes(
      b"\xef\xbb\xbf" + sig.to_json_bytes(),
    ),
    Err(@manifest.InvalidEncoding),
  )
  let dup_sig = sig_text.replace(
    old="\"schema\":1,",
    new="\"schema\":1,\"schema\":1,",
  )
  match
    @manifest.DirManifestSignature::from_json_bytes(@utf8.encode(dup_sig[:])) {
    Err(@manifest.InvalidJson(field=Some("schema"), ..)) => ()
    other => abort("expected InvalidJson, got \{@debug.to_string(other)}")
  }
  let unknown_sig = sig_text.replace(
    old="\"schema\":1,",
    new="\"schema\":1,\"extra\":1,",
  )
  match
    @manifest.DirManifestSignature::from_json_bytes(
      @utf8.encode(unknown_sig[:]),
    ) {
    Err(@manifest.InvalidSchema(field="extra", ..)) => ()
    other => abort("expected InvalidSchema, got \{@debug.to_string(other)}")
  }

  // Non-canonical small-order R point rejected by DirManifestSignature::from_json_bytes.
  let small_order_r = "0100000000000000000000000000000000000000000000000000000000000000"
  let zero_s = "0000000000000000000000000000000000000000000000000000000000000000"
  let bad_r_sig = sig_text.replace(
    old=sig.signature_hex(),
    new=small_order_r + zero_s,
  )
  match
    @manifest.DirManifestSignature::from_json_bytes(@utf8.encode(bad_r_sig[:])) {
    Err(@manifest.InvalidSignatureFormat(..)) => ()
    other =>
      abort("expected InvalidSignatureFormat, got \{@debug.to_string(other)}")
  }

  // Manifest edge invariants: renamed path == from_path, path both added & deleted,
  // and nonzero old_total_bytes when old_file_count == 0.
  let id_x = @manifest.ContentIdentity::of_bytes(b"x")
  let empty_tree = @manifest.tree_sha256([]).unwrap()
  let self_rename_json = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{empty_tree}\"," +
    "\"new_tree_sha256\":\"\{empty_tree}\"," +
    "\"old_file_count\":1,\"new_file_count\":1," +
    "\"old_total_bytes\":\"1\",\"new_total_bytes\":\"1\",\"delta_payload_bytes\":\"0\"," +
    "\"entries\":[" +
    "{\"action\":\"renamed\",\"path\":\"x.txt\",\"from_path\":\"x.txt\",\"identity\":{\"size_bytes\":\"1\",\"sha256\":\"\{id_x.hash}\"}}" +
    "]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(self_rename_json) {
    Err(@manifest.InvalidSchema(field="entries[0].from_path", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for self-rename, got \{@debug.to_string(other)}",
      )
  }

  let add_and_delete_json = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{empty_tree}\"," +
    "\"new_tree_sha256\":\"\{empty_tree}\"," +
    "\"old_file_count\":1,\"new_file_count\":1," +
    "\"old_total_bytes\":\"1\",\"new_total_bytes\":\"1\",\"delta_payload_bytes\":\"1\"," +
    "\"entries\":[" +
    "{\"action\":\"added\",\"path\":\"x.txt\",\"identity\":{\"size_bytes\":\"1\",\"sha256\":\"\{id_x.hash}\"},\"blob_name\":\"blob-0001.full\",\"full_fallback\":false}," +
    "{\"action\":\"deleted\",\"path\":\"x.txt\",\"old_identity\":{\"size_bytes\":\"1\",\"sha256\":\"\{id_x.hash}\"}}" +
    "]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(add_and_delete_json) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for added+deleted overlap, got \{@debug.to_string(other)}",
      )
  }

  let bad_empty_old_json = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{empty_tree}\"," +
    "\"new_tree_sha256\":\"\{empty_tree}\"," +
    "\"old_file_count\":0,\"new_file_count\":0," +
    "\"old_total_bytes\":\"5\",\"new_total_bytes\":\"0\",\"delta_payload_bytes\":\"0\"," +
    "\"entries\":[]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(bad_empty_old_json) {
    Err(@manifest.InvalidSchema(field="old_total_bytes", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for nonzero old_total_bytes with 0 files, got \{@debug.to_string(other)}",
      )
  }

  // Contradictory old_total_bytes < sum(old_asserted_sizes) rejected before signing.
  let old_a = b"aaaa"
  let id_a = @manifest.ContentIdentity::of_bytes(old_a)
  let tree_a = @manifest.tree_sha256([{ path: "a.txt", bytes: old_a, }]).unwrap()
  let bad_old_sum_json = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{tree_a}\"," +
    "\"new_tree_sha256\":\"\{tree_a}\"," +
    "\"old_file_count\":1,\"new_file_count\":1," +
    "\"old_total_bytes\":\"2\",\"new_total_bytes\":\"4\",\"delta_payload_bytes\":\"0\"," +
    "\"entries\":[" +
    "{\"action\":\"unchanged\",\"path\":\"a.txt\",\"identity\":{\"size_bytes\":\"4\",\"sha256\":\"\{id_a.hash}\"}}" +
    "]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(bad_old_sum_json) {
    Err(@manifest.InvalidSchema(field="old_total_bytes", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema for old_total_bytes < asserted sum, got \{@debug.to_string(other)}",
      )
  }
  match sk.sign_dir_manifest(bad_old_sum_json) {
    Err(@manifest.InvalidSchema(field="old_total_bytes", ..)) => ()
    other =>
      abort(
        "expected sign_dir_manifest to reject contradictory old_total_bytes, got \{@debug.to_string(other)}",
      )
  }

  // Impossible old_file_count > new_file_count + deleted_count rejected right at
  // parse & sign time (both empty-entries 2147483647 PoC and 2 > 1 + 0).
  let impossible_old_count_json = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{empty_tree}\"," +
    "\"new_tree_sha256\":\"\{empty_tree}\"," +
    "\"old_file_count\":2147483647,\"new_file_count\":0," +
    "\"old_total_bytes\":\"9223372036854775807\",\"new_total_bytes\":\"0\",\"delta_payload_bytes\":\"0\"," +
    "\"entries\":[]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(impossible_old_count_json) {
    Err(@manifest.InvalidSchema(field="old_file_count", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema(old_file_count) on impossible old_file_count, got \{@debug.to_string(other)}",
      )
  }
  match sk.sign_dir_manifest(impossible_old_count_json) {
    Err(@manifest.InvalidSchema(field="old_file_count", ..)) => ()
    other =>
      abort(
        "expected sign_dir_manifest to reject impossible old_file_count, got \{@debug.to_string(other)}",
      )
  }

  let old_ab : Array[@manifest.DirFileEntry] = [
    { path: "a.txt", bytes: old_a, },
    { path: "b.txt", bytes: b"bbbbbb", },
  ]
  let tree_ab = @manifest.tree_sha256(old_ab).unwrap()
  let impossible_drop_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{tree_ab}\"," +
    "\"new_tree_sha256\":\"\{tree_a}\"," +
    "\"old_file_count\":2,\"new_file_count\":1," +
    "\"old_total_bytes\":\"10\",\"new_total_bytes\":\"4\",\"delta_payload_bytes\":\"0\"," +
    "\"entries\":[" +
    "{\"action\":\"unchanged\",\"path\":\"a.txt\",\"identity\":{\"size_bytes\":\"4\",\"sha256\":\"\{id_a.hash}\"}}" +
    "]}\n")[:],
  )
  match @manifest.DirManifest::from_json_bytes(impossible_drop_manifest) {
    Err(@manifest.InvalidSchema(field="old_file_count", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema(old_file_count) on 2 > 1 + 0 manifest, got \{@debug.to_string(other)}",
      )
  }

  // Silent deletion that satisfies old_file_count <= new_file_count + deleted
  // (replacing omitted b.txt with an Added c.txt without a Deleted entry for b.txt)
  // is still rejected fail-closed by dir_apply.
  let c_bytes = b"cccccc"
  let id_c = @manifest.ContentIdentity::of_bytes(c_bytes)
  let tree_ac = @manifest.tree_sha256([
    { path: "a.txt", bytes: old_a, },
    { path: "c.txt", bytes: c_bytes, },
  ]).unwrap()
  let silent_del_manifest = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{tree_ab}\"," +
    "\"new_tree_sha256\":\"\{tree_ac}\"," +
    "\"old_file_count\":2,\"new_file_count\":2," +
    "\"old_total_bytes\":\"10\",\"new_total_bytes\":\"10\",\"delta_payload_bytes\":\"6\"," +
    "\"entries\":[" +
    "{\"action\":\"unchanged\",\"path\":\"a.txt\",\"identity\":{\"size_bytes\":\"4\",\"sha256\":\"\{id_a.hash}\"}}," +
    "{\"action\":\"added\",\"path\":\"c.txt\",\"identity\":{\"size_bytes\":\"6\",\"sha256\":\"\{id_c.hash}\"},\"blob_name\":\"blob-0001.full\",\"full_fallback\":true}" +
    "]}\n")[:],
  )
  assert_true(
    @manifest.DirManifest::from_json_bytes(silent_del_manifest) is Ok(_),
  )
  match
    @manifest.dir_apply(
      old_ab,
      silent_del_manifest,
      [{ name: "blob-0001.full", bytes: c_bytes, }],
      @moonbsdiff.Limits::for_apply(),
    ) {
    Err(@manifest.InvalidSchema(field="entries", ..)) => ()
    other =>
      abort(
        "expected InvalidSchema(entries) on silent deletion, got \{@debug.to_string(other)}",
      )
  }

  // Deeply nested shared directory prefixes validate fast via cached right-to-left
  // ancestor checking and still detect deep file-vs-directory collisions.
  let deep_dir = dir_test_repeat_char("a/", 200)
  let deep_entries : Array[@manifest.DirFileEntry] = []
  for i = 0; i < 64; i = i + 1 {
    deep_entries.push({ path: deep_dir + "f\{i}", bytes: b"", })
  }
  assert_true(@manifest.tree_sha256(deep_entries) is Ok(_))
  let deep_collision = deep_entries.copy()
  let collider_dir = dir_test_repeat_char("a/", 100) + "a"
  deep_collision.push({ path: collider_dir, bytes: b"", })
  match @manifest.tree_sha256(deep_collision) {
    Err(@manifest.PathCollision(a~, ..)) => assert_eq(a, collider_dir)
    other =>
      abort(
        "expected PathCollision on deep shared prefix, got \{@debug.to_string(other)}",
      )
  }

  // Zero-alloc slash-first prefix-collision checks handle ASCII ordering gaps
  // ('-'=45, '.'=46 < '/'=47), nested dirs, SMP emoji, and UTF-8 canonical order.
  match
    @manifest.tree_sha256([
      { path: "a", bytes: b"", },
      { path: "a-1", bytes: b"", },
      { path: "a.txt", bytes: b"", },
      { path: "a/b", bytes: b"", },
      { path: "a/b/c", bytes: b"", },
    ]) {
    Err(@manifest.PathCollision(a="a", b="a/b")) => ()
    other =>
      abort(
        "expected PathCollision(a, a/b) across '-' and '.', got \{@debug.to_string(other)}",
      )
  }
  assert_true(
    @manifest.tree_sha256([
      { path: "a-1", bytes: b"", },
      { path: "a.txt", bytes: b"", },
      { path: "a/b", bytes: b"", },
    ])
    is Ok(_),
  )
  match
    @manifest.tree_sha256([
      { path: "a/b", bytes: b"", },
      { path: "a/b-1", bytes: b"", },
      { path: "a/b.txt", bytes: b"", },
      { path: "a/b/c", bytes: b"", },
    ]) {
    Err(@manifest.PathCollision(a="a/b", b="a/b/c")) => ()
    other =>
      abort(
        "expected PathCollision(a/b, a/b/c), got \{@debug.to_string(other)}",
      )
  }
  match
    @manifest.tree_sha256([
      { path: "\u{1F525}", bytes: b"", },
      { path: "\u{1F525}-1", bytes: b"", },
      { path: "\u{1F525}/x", bytes: b"", },
    ]) {
    Err(@manifest.PathCollision(a="\u{1F525}", b="\u{1F525}/x")) => ()
    other =>
      abort(
        "expected PathCollision on SMP emoji path, got \{@debug.to_string(other)}",
      )
  }
  // Canonical UTF-8 byte order must place BMP U+E000..U+FFFF before SMP U+10000+
  // (unlike raw UTF-16 code-unit order where surrogates 0xD800..0xDFFF precede 0xE000).
  let unicode_bundle = @manifest.dir_diff(
    [],
    [
      { path: "\u{1F525}", bytes: b"1", },
      { path: "\u{FF01}", bytes: b"2", },
      { path: "\u{E000}", bytes: b"3", },
      { path: "\u{D7FF}", bytes: b"4", },
      { path: "a", bytes: b"5", },
    ],
    @moonbsdiff.Limits::for_diff(),
  ).unwrap()
  let ordered_paths : Array[String] = []
  for entry in unicode_bundle.manifest.entries {
    match entry {
      Added(path~, ..) => ordered_paths.push(path)
      _ => abort("expected Added entries")
    }
  }
  assert_eq(ordered_paths, [
    "a", "\u{D7FF}", "\u{E000}", "\u{FF01}", "\u{1F525}",
  ])

  // Disjoint deep-path manifest (#59 PoC: 430 disjoint 1022-byte paths <= 512 KiB)
  // must parse with O(1) extra memory (no full-prefix map explosion) and still
  // detect a deep disjoint ancestor collision.
  let disjoint_tail = dir_test_repeat_char("a/", 508) + "z"
  let empty_id = @manifest.ContentIdentity::of_bytes(b"")
  let disjoint_entries : Array[@manifest.DirFileEntry] = []
  let disjoint_json = StringBuilder()
  for i = 0; i < 430; i = i + 1 {
    let p = if i < 10 {
      "p00\{i}/" + disjoint_tail
    } else if i < 100 {
      "p0\{i}/" + disjoint_tail
    } else {
      "p\{i}/" + disjoint_tail
    }
    disjoint_entries.push({ path: p, bytes: b"", })
    if i > 0 {
      disjoint_json.write_string(",")
    }
    disjoint_json.write_string(
      "{\"action\":\"unchanged\",\"path\":\"\{p}\",\"identity\":{\"size_bytes\":\"0\",\"sha256\":\"\{empty_id.hash}\"}}",
    )
  }
  let disjoint_tree = @manifest.tree_sha256(disjoint_entries).unwrap()
  let disjoint_manifest_bytes = @utf8.encode(
    ("{\"schema\":1,\"type\":\"moonbsdiff-dir-manifest\"," +
    "\"old_tree_sha256\":\"\{disjoint_tree}\"," +
    "\"new_tree_sha256\":\"\{disjoint_tree}\"," +
    "\"old_file_count\":430,\"new_file_count\":430," +
    "\"old_total_bytes\":\"0\",\"new_total_bytes\":\"0\",\"delta_payload_bytes\":\"0\"," +
    "\"entries\":[" +
    disjoint_json.to_string() +
    "]}\n")[:],
  )
  assert_true(
    disjoint_manifest_bytes.length() <= @manifest.max_dir_manifest_bytes,
  )
  let parsed_disjoint = @manifest.DirManifest::from_json_bytes(
    disjoint_manifest_bytes,
  ).unwrap()
  assert_eq(parsed_disjoint.new_file_count, 430)
  let disjoint_with_collision = disjoint_entries.copy()
  disjoint_with_collision.push({ path: "p215/a/a", bytes: b"", })
  match @manifest.tree_sha256(disjoint_with_collision) {
    Err(@manifest.PathCollision(a="p215/a/a", ..)) => ()
    other =>
      abort(
        "expected PathCollision(p215/a/a) on disjoint deep tree, got \{@debug.to_string(other)}",
      )
  }
}
