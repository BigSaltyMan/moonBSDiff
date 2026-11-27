///|
fn test_hex_nibble(byte : Byte) -> Int32 {
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
fn test_from_hex(hex : String) -> Bytes {
  let encoded = @utf8.encode(hex[:])
  if encoded.length() % 2 != 0 {
    abort("odd hex length")
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < encoded.length() {
    let hi = test_hex_nibble(encoded[i])
    let lo = test_hex_nibble(encoded[i + 1])
    out.push(((hi << 4) | lo).to_byte())
    i = i + 2
  }
  Bytes::from_array(out)
}

///|
fn test_to_hex(bytes : Bytes) -> String {
  let out = StringBuilder(capacity=bytes.length() * 2)
  for byte in bytes {
    out.write_string(byte.to_hex())
  }
  out.to_string()
}

///|
fn test_le_bigint(bytes : BytesView) -> BigInt {
  let be : Array[Byte] = []
  for i = bytes.length() - 1; i >= 0; i = i - 1 {
    be.push(bytes[i])
  }
  BigInt::from_octets(Bytes::from_array(be)[:])
}

///|
fn test_bigint_to_le32(n : BigInt) -> Bytes {
  let be = n.to_octets(length=32)
  let le : Array[Byte] = []
  for i = 31; i >= 0; i = i - 1 {
    le.push(be[i])
  }
  Bytes::from_array(le)
}

///|
fn test_utf8_decode(bytes : Bytes) -> String {
  @utf8.decode(bytes[:], ignore_bom=false) catch {
    _ => abort("unexpected invalid UTF-8 in test")
  }
}

///|
fn test_ed25519_l() -> BigInt {
  ((1 : BigInt) << 252) +
  (try! @string.parse_bigint("27742317777372353535851937790883648493"))
}

///|
fn test_sample_manifest() -> Bytes {
  @utf8.encode(
    ("{\"schema_version\":1,\"patch_format\":\"BSDIFF40\"," +
    "\"producer\":{\"name\":\"moonbsdiff\",\"version\":\"0.5.4\"}," +
    "\"old\":{\"size_bytes\":\"20\",\"sha256\":\"6bc14bdc4517a7a682c6910de2e2946eb8e1ecd04090728fef6d092a7ceb62c5\"}," +
    "\"new\":{\"size_bytes\":\"20\",\"sha256\":\"5719410b795aeecf690587cb18dfa92f4bc7c7c9c46662343faaa6dee218fa79\"}," +
    "\"patch\":{\"size_bytes\":\"134\",\"sha256\":\"cd22b7f1c8031af0f84f610b967771311791007e33914b64d8ef81cfd58a7c6b\"}}\n")[:],
  )
}

///|
fn test_small_order_points_hex() -> Array[String] {
  [
    "0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000080",
    "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a", "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
    "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05", "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
  ]
}

///|
test "signature RFC 8032 test vectors 1 2 3 key derivation and raw primitive" {
  let vectors = [
    (
      "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
      "21fe31dfa154a261", "", "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
    ),
    (
      "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
      "", "72", "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
    ),
    (
      "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7", "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
      "", "af82", "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
    ),
  ]
  for vec in vectors {
    let (seed_hex, want_pub_hex, want_key_id, msg_hex, want_sig_hex) = vec
    let seed = test_from_hex(seed_hex)
    let sk = @manifest.PrivateKey::from_seed(seed).unwrap()
    let pk = sk.public_key()
    assert_eq(pk.to_hex(), want_pub_hex)
    assert_eq(pk.to_bytes(), test_from_hex(want_pub_hex))
    assert_eq(sk.key_id(), pk.key_id())
    if want_key_id != "" {
      assert_eq(pk.key_id(), want_key_id)
    }
    assert_eq(@manifest.PublicKey::from_bytes(pk.to_bytes()), Ok(pk))

    // Cross-check underlying mooncrypt RFC 8032 sign/verify on all targets.
    let ed_sk = @ed25519.PrivateKey::new(seed[:]) catch {
      _ => abort("unexpected ed25519 PrivateKey error")
    }
    let ed_pk = @ed25519.PublicKey::new(test_from_hex(want_pub_hex)[:]) catch {
      _ => abort("unexpected ed25519 PublicKey error")
    }
    let msg = test_from_hex(msg_hex)
    let raw_sig = ed_sk.sign(msg[:])
    assert_eq(test_to_hex(raw_sig), want_sig_hex)
    assert_true(ed_pk.verify(msg[:], test_from_hex(want_sig_hex)[:]))
  }
}

///|
test "signature domain separation and JSON roundtrips" {
  let seed = test_from_hex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
  )
  let sk = @manifest.PrivateKey::from_seed(seed).unwrap()
  let pk = sk.public_key()
  let manifest_bytes = test_sample_manifest()
  let sig = sk.sign_manifest(manifest_bytes).unwrap()

  assert_eq(sig.key_id(), pk.key_id())
  assert_eq(sig.signature_bytes().length(), 64)
  assert_eq(test_to_hex(sig.signature_bytes()), sig.signature_hex())
  assert_eq(
    @manifest.verify_manifest_signature(manifest_bytes, sig, pk),
    Ok(()),
  )
  assert_eq(
    @manifest.verify_raw_signature(manifest_bytes, sig.signature_bytes(), pk),
    Ok(()),
  )

  // Verify JSON serialization matches exact schema and roundtrips cleanly.
  let pk_json = pk.to_json_bytes()
  let pk_str = test_utf8_decode(pk_json)
  assert_eq(
    pk_str,
    "{\"schema_version\":1,\"format\":\"moonbsdiff-ed25519-public-key\",\"algorithm\":\"ed25519\",\"public_key\":\"\{pk.to_hex()}\",\"key_id\":\"\{pk.key_id()}\"}\n",
  )
  assert_eq(@manifest.PublicKey::from_json_bytes(pk_json), Ok(pk))

  let sk_json = sk.to_json_bytes()
  let sk_str = test_utf8_decode(sk_json)
  assert_eq(
    sk_str,
    "{\"schema_version\":1,\"format\":\"moonbsdiff-ed25519-private-key\",\"algorithm\":\"ed25519\",\"seed\":\"\{test_to_hex(seed)}\",\"public_key\":\"\{pk.to_hex()}\",\"key_id\":\"\{pk.key_id()}\"}\n",
  )
  let sk_roundtrip = @manifest.PrivateKey::from_json_bytes(sk_json).unwrap()
  assert_eq(sk_roundtrip.public_key(), pk)
  assert_eq(sk_roundtrip.sign_manifest(manifest_bytes), Ok(sig))

  let sig_json = sig.to_json_bytes()
  let sig_str = test_utf8_decode(sig_json)
  assert_eq(
    sig_str,
    "{\"schema_version\":1,\"format\":\"moonbsdiff-manifest-signature\",\"algorithm\":\"ed25519\",\"key_id\":\"\{sig.key_id()}\",\"manifest_sha256\":\"\{sig.manifest_sha256()}\",\"signature\":\"\{sig.signature_hex()}\"}\n",
  )
  assert_eq(@manifest.ManifestSignature::from_json_bytes(sig_json), Ok(sig))
  assert_eq(
    @manifest.verify_manifest_signature_bytes(manifest_bytes, sig_json, pk_json),
    Ok(sig),
  )

  // Cross-domain rejection: raw Ed25519 signature over manifest_bytes WITHOUT
  // domain prefix must fail verify_raw_signature!
  let ed_sk = @ed25519.PrivateKey::new(seed[:]) catch {
    _ => abort("unexpected ed25519 PrivateKey error")
  }
  let raw_no_domain_sig = ed_sk.sign(manifest_bytes[:])
  assert_eq(
    @manifest.verify_raw_signature(manifest_bytes, raw_no_domain_sig, pk),
    Err(@manifest.VerificationFailed),
  )

  // Conversely, our domain-separated signature must NOT verify as raw manifest_bytes
  // without the domain prefix, and MUST verify when prefixed.
  let ed_pk = @ed25519.PublicKey::new(pk.to_bytes()[:]) catch {
    _ => abort("unexpected ed25519 PublicKey error")
  }
  assert_false(ed_pk.verify(manifest_bytes[:], sig.signature_bytes()[:]))
  let prefixed = b"moonbsdiff-manifest-ed25519-v1\x00" + manifest_bytes
  assert_true(ed_pk.verify(prefixed[:], sig.signature_bytes()[:]))
}

///|
test "signature bit flips wrong key and length limits" {
  let seed_a = test_from_hex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
  )
  let seed_b = test_from_hex(
    "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
  )
  let sk_a = @manifest.PrivateKey::from_seed(seed_a).unwrap()
  let pk_a = sk_a.public_key()
  let pk_b = @manifest.PrivateKey::from_seed(seed_b).unwrap().public_key()
  let manifest_bytes = test_sample_manifest()
  let sig = sk_a.sign_manifest(manifest_bytes).unwrap()

  // Length checks on raw keys and signatures.
  assert_eq(
    @manifest.PublicKey::from_bytes(Bytes::make(31, b'\x00')),
    Err(@manifest.InvalidKeyLength(expected=32, actual=31)),
  )
  assert_eq(
    @manifest.PublicKey::from_bytes(Bytes::make(33, b'\x00')),
    Err(@manifest.InvalidKeyLength(expected=32, actual=33)),
  )
  match @manifest.PrivateKey::from_seed(Bytes::make(31, b'\x00')) {
    Err(@manifest.InvalidKeyLength(expected=32, actual=31)) => ()
    _ => abort("expected InvalidKeyLength for 31-byte seed")
  }
  assert_eq(
    @manifest.verify_raw_signature(
      manifest_bytes,
      Bytes::make(63, b'\x00'),
      pk_a,
    ),
    Err(@manifest.InvalidSignatureLength(expected=64, actual=63)),
  )

  // Oversized manifest checks (> 16384 bytes).
  let oversized_manifest = Bytes::make(16385, b'a')
  assert_eq(
    sk_a.sign_manifest(oversized_manifest),
    Err(
      @manifest.LimitExceeded(
        field="max_manifest_bytes",
        value=16385L,
        limit=16384L,
      ),
    ),
  )
  assert_eq(
    @manifest.verify_manifest_signature(oversized_manifest, sig, pk_a),
    Err(
      @manifest.LimitExceeded(
        field="max_manifest_bytes",
        value=16385L,
        limit=16384L,
      ),
    ),
  )
  assert_eq(
    @manifest.verify_raw_signature(
      oversized_manifest,
      sig.signature_bytes(),
      pk_a,
    ),
    Err(
      @manifest.LimitExceeded(
        field="max_manifest_bytes",
        value=16385L,
        limit=16384L,
      ),
    ),
  )

  // Manifest bit-flip.
  let flipped_manifest = manifest_bytes[:10].to_owned() +
    Bytes::from_array([(manifest_bytes[10].to_int() ^ 1).to_byte()]) +
    manifest_bytes[11:].to_owned()
  match @manifest.verify_manifest_signature(flipped_manifest, sig, pk_a) {
    Err(@manifest.ManifestHashMismatch(..)) => ()
    _ => abort("expected ManifestHashMismatch on flipped manifest")
  }
  assert_eq(
    @manifest.verify_raw_signature(
      flipped_manifest,
      sig.signature_bytes(),
      pk_a,
    ),
    Err(@manifest.VerificationFailed),
  )

  // Wrong public key.
  assert_eq(
    @manifest.verify_manifest_signature(manifest_bytes, sig, pk_b),
    Err(@manifest.KeyIdMismatch(expected=pk_b.key_id(), actual=pk_a.key_id())),
  )
  assert_eq(
    @manifest.verify_raw_signature(manifest_bytes, sig.signature_bytes(), pk_b),
    Err(@manifest.VerificationFailed),
  )

  // Bit-flip in signature S (low bit keeps S < L -> VerificationFailed; top bit makes S >= L -> InvalidSignatureFormat).
  let raw_sig = sig.signature_bytes()
  let bent_s_low = raw_sig.to_array()
  bent_s_low[32] = (bent_s_low[32].to_int() ^ 1).to_byte()
  assert_eq(
    @manifest.verify_raw_signature(
      manifest_bytes,
      Bytes::from_array(bent_s_low),
      pk_a,
    ),
    Err(@manifest.VerificationFailed),
  )
  let bent_s_high = raw_sig.to_array()
  bent_s_high[63] = (bent_s_high[63].to_int() | 0x80).to_byte()
  match
    @manifest.verify_raw_signature(
      manifest_bytes,
      Bytes::from_array(bent_s_high),
      pk_a,
    ) {
    Err(@manifest.InvalidSignatureFormat(..)) => ()
    _ => abort("expected InvalidSignatureFormat when high bit of S is set")
  }

  // Bit-flip in signature R: rejects with either VerificationFailed or InvalidSignatureFormat.
  let bent_r = raw_sig.to_array()
  bent_r[0] = (bent_r[0].to_int() ^ 1).to_byte()
  match
    @manifest.verify_raw_signature(
      manifest_bytes,
      Bytes::from_array(bent_r),
      pk_a,
    ) {
    Err(@manifest.VerificationFailed)
    | Err(@manifest.InvalidSignatureFormat(..)) => ()
    _ =>
      abort("expected VerificationFailed or InvalidSignatureFormat on bent R")
  }
}

///|
test "signature adversarial crypto malleability non-canonical off-curve and torsion" {
  let seed = test_from_hex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
  )
  let sk = @manifest.PrivateKey::from_seed(seed).unwrap()
  let pk = sk.public_key()
  let manifest_bytes = test_sample_manifest()
  let sig = sk.sign_manifest(manifest_bytes).unwrap()
  let raw_sig = sig.signature_bytes()
  let r_bytes = raw_sig[0:32].to_owned()
  let s_valid = test_le_bigint(raw_sig[32:64])
  let l = test_ed25519_l()

  // 1. S = L and S = S_valid + L malleability rejected in raw verify and signature JSON.
  let s_eq_l_sig = r_bytes + test_bigint_to_le32(l)
  let s_plus_l_sig = r_bytes + test_bigint_to_le32(s_valid + l)
  for bad_sig in [s_eq_l_sig, s_plus_l_sig] {
    match @manifest.verify_raw_signature(manifest_bytes, bad_sig, pk) {
      Err(@manifest.InvalidSignatureFormat(..)) => ()
      _ => abort("expected InvalidSignatureFormat for malleable S >= L")
    }
    let bad_json = @utf8.encode(
      ("{\"schema_version\":1,\"format\":\"moonbsdiff-manifest-signature\",\"algorithm\":\"ed25519\"," +
      "\"key_id\":\"\{pk.key_id()}\",\"manifest_sha256\":\"\{sig.manifest_sha256()}\"," +
      "\"signature\":\"\{test_to_hex(bad_sig)}\"}\n")[:],
    )
    match @manifest.ManifestSignature::from_json_bytes(bad_json) {
      Err(@manifest.InvalidSignatureFormat(..)) => ()
      _ => abort("expected InvalidSignatureFormat in signature JSON for S >= L")
    }
  }

  // 2. Non-canonical y = p, y = p + 1, non-canonical x=0 sign=1, off-curve y = 2,
  //    and ALL 8 small-order torsion points E[8] rejected in BOTH PublicKey and R.
  let bad_points : Array[String] = [
    // y = p
    "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    // y = p (with sign bit = 1)
     "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    // y = p + 1
     "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    // x == 0 && sign == 1 (y = 1, sign = 1)
     "0100000000000000000000000000000000000000000000000000000000000080",
    // x == 0 && sign == 1 (y = p - 1, sign = 1)
     "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    // off-curve y = 2
     "0200000000000000000000000000000000000000000000000000000000000000",
    // off-curve y = 2 (with sign bit = 1)
     "0200000000000000000000000000000000000000000000000000000000000080",
  ]
  for torsion in test_small_order_points_hex() {
    bad_points.push(torsion)
  }

  for pt_hex in bad_points {
    let pt_bytes = test_from_hex(pt_hex)
    match @manifest.PublicKey::from_bytes(pt_bytes) {
      Err(@manifest.InvalidPublicKey(..)) => ()
      _ => abort("PublicKey::from_bytes accepted bad point: " + pt_hex)
    }
    let bad_pk_json = @utf8.encode(
      ("{\"schema_version\":1,\"format\":\"moonbsdiff-ed25519-public-key\",\"algorithm\":\"ed25519\"," +
      "\"public_key\":\"\{pt_hex}\",\"key_id\":\"0000000000000000\"}\n")[:],
    )
    match @manifest.PublicKey::from_json_bytes(bad_pk_json) {
      Err(@manifest.InvalidPublicKey(..)) => ()
      _ => abort("PublicKey::from_json_bytes accepted bad point: " + pt_hex)
    }
    let bad_sig = pt_bytes + raw_sig[32:64].to_owned()
    match @manifest.verify_raw_signature(manifest_bytes, bad_sig, pk) {
      Err(@manifest.InvalidSignatureFormat(..)) => ()
      _ => abort("verify_raw_signature accepted bad R point: " + pt_hex)
    }
    let bad_sig_json = @utf8.encode(
      ("{\"schema_version\":1,\"format\":\"moonbsdiff-manifest-signature\",\"algorithm\":\"ed25519\"," +
      "\"key_id\":\"\{pk.key_id()}\",\"manifest_sha256\":\"\{sig.manifest_sha256()}\"," +
      "\"signature\":\"\{pt_hex}\{test_to_hex(raw_sig[32:64].to_owned())}\"}\n")[:],
    )
    match @manifest.ManifestSignature::from_json_bytes(bad_sig_json) {
      Err(@manifest.InvalidSignatureFormat(..)) => ()
      _ => abort("ManifestSignature::from_json_bytes accepted bad R: " + pt_hex)
    }
  }

  // 3. Specifically verify forged signature (R=(0,1), S=0) is rejected.
  let forged_r01_s0 = test_from_hex(
    "0100000000000000000000000000000000000000000000000000000000000000" +
    "0000000000000000000000000000000000000000000000000000000000000000",
  )
  match @manifest.verify_raw_signature(manifest_bytes, forged_r01_s0, pk) {
    Err(@manifest.InvalidSignatureFormat(..)) => ()
    _ => abort("forged signature (R=(0,1), S=0) was accepted")
  }
}

///|
test "signature JSON envelope strict validation rejections" {
  let seed = test_from_hex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
  )
  let sk = @manifest.PrivateKey::from_seed(seed).unwrap()
  let pk = sk.public_key()
  let sig = sk.sign_manifest(test_sample_manifest()).unwrap()

  let pk_json = pk.to_json_bytes()
  let sk_json = sk.to_json_bytes()
  let sig_json = sig.to_json_bytes()
  let pk_str = test_utf8_decode(pk_json)
  let sk_str = test_utf8_decode(sk_json)
  let sig_str = test_utf8_decode(sig_json)

  // > 4096 bytes checked BEFORE UTF-8 decode (invalid UTF-8 bytes on purpose).
  let oversized = Bytes::make(4097, b'\xff')
  assert_eq(
    @manifest.PublicKey::from_json_bytes(oversized),
    Err(
      @manifest.LimitExceeded(
        field="max_key_file_bytes",
        value=4097L,
        limit=4096L,
      ),
    ),
  )
  match @manifest.PrivateKey::from_json_bytes(oversized) {
    Err(
      @manifest.LimitExceeded(
        field="max_key_file_bytes",
        value=4097L,
        limit=4096L,
      ),
    ) => ()
    _ => abort("expected LimitExceeded for oversized private key JSON")
  }
  assert_eq(
    @manifest.ManifestSignature::from_json_bytes(oversized),
    Err(
      @manifest.LimitExceeded(
        field="max_signature_file_bytes",
        value=4097L,
        limit=4096L,
      ),
    ),
  )

  // UTF-8 BOM and invalid UTF-8 rejected as InvalidEncoding.
  assert_eq(
    @manifest.PublicKey::from_json_bytes(b"\xef\xbb\xbf" + pk_json),
    Err(@manifest.InvalidEncoding),
  )
  assert_eq(
    @manifest.ManifestSignature::from_json_bytes(b"\xef\xbb\xbf" + sig_json),
    Err(@manifest.InvalidEncoding),
  )
  assert_eq(
    @manifest.PublicKey::from_json_bytes(b"\xff\xfe"),
    Err(@manifest.InvalidEncoding),
  )

  // Duplicate key (including JSON escape duplicate).
  let dup_pk = b"{\"\\u0073chema_version\":1," + pk_json[1:].to_owned()
  match @manifest.PublicKey::from_json_bytes(dup_pk) {
    Err(@manifest.InvalidJson(field=Some("schema_version"), ..)) => ()
    _ => abort("expected InvalidJson duplicate key on public key")
  }
  let dup_sig = b"{\"key_id\":\"0000000000000000\"," + sig_json[1:].to_owned()
  match @manifest.ManifestSignature::from_json_bytes(dup_sig) {
    Err(@manifest.InvalidJson(field=Some("key_id"), ..)) => ()
    _ => abort("expected InvalidJson duplicate key on signature")
  }

  // Unknown key and missing key.
  let unknown_pk = @utf8.encode(pk_str.replace(old="}", new=",\"extra\":1}")[:])
  match @manifest.PublicKey::from_json_bytes(unknown_pk) {
    Err(@manifest.InvalidSchema(field="extra", ..)) => ()
    _ => abort("expected InvalidSchema unknown field")
  }
  let missing_sig = @utf8.encode(
    sig_str.replace(old=",\"signature\":\"\{sig.signature_hex()}\"", new="")[:],
  )
  match @manifest.ManifestSignature::from_json_bytes(missing_sig) {
    Err(@manifest.InvalidSchema(field="signature", ..)) => ()
    _ => abort("expected InvalidSchema missing field")
  }

  // Wrong schema_version (1.0, 2, "1").
  for bad_ver in ["1.0", "2", "\"1\""] {
    let bad_pk = @utf8.encode(
      pk_str.replace(
        old="\"schema_version\":1",
        new="\"schema_version\":" + bad_ver,
      )[:],
    )
    match @manifest.PublicKey::from_json_bytes(bad_pk) {
      Err(@manifest.InvalidSchema(field="schema_version", ..)) => ()
      _ => abort("accepted bad schema_version: " + bad_ver)
    }
  }

  // Wrong format and algorithm.
  let bad_fmt = @utf8.encode(
    pk_str.replace(
      old="\"moonbsdiff-ed25519-public-key\"",
      new="\"wrong-format\"",
    )[:],
  )
  match @manifest.PublicKey::from_json_bytes(bad_fmt) {
    Err(@manifest.InvalidSchema(field="format", ..)) => ()
    _ => abort("accepted wrong format")
  }
  let bad_alg = @utf8.encode(
    sig_str.replace(old="\"ed25519\"", new="\"ed448\"")[:],
  )
  match @manifest.ManifestSignature::from_json_bytes(bad_alg) {
    Err(@manifest.InvalidSchema(field="algorithm", ..)) => ()
    _ => abort("accepted wrong algorithm")
  }

  // Uppercase hex rejected in all envelopes.
  let upper_pk_hex = pk.to_hex().to_upper()
  let upper_pk = @utf8.encode(
    pk_str.replace(old=pk.to_hex(), new=upper_pk_hex)[:],
  )
  match @manifest.PublicKey::from_json_bytes(upper_pk) {
    Err(@manifest.InvalidSchema(field="public_key", ..)) => ()
    _ => abort("accepted uppercase public_key hex")
  }
  let upper_sig = @utf8.encode(
    sig_str.replace(old=sig.signature_hex(), new=sig.signature_hex().to_upper())[:],
  )
  match @manifest.ManifestSignature::from_json_bytes(upper_sig) {
    Err(@manifest.InvalidSchema(field="signature", ..)) => ()
    _ => abort("accepted uppercase signature hex")
  }

  // key_id mismatch in pubkey and privkey JSON.
  let wrong_id = "0000000000000000"
  let bad_pk_id = @utf8.encode(pk_str.replace(old=pk.key_id(), new=wrong_id)[:])
  assert_eq(
    @manifest.PublicKey::from_json_bytes(bad_pk_id),
    Err(@manifest.KeyIdMismatch(expected=pk.key_id(), actual=wrong_id)),
  )
  let bad_sk_id = @utf8.encode(sk_str.replace(old=pk.key_id(), new=wrong_id)[:])
  match @manifest.PrivateKey::from_json_bytes(bad_sk_id) {
    Err(@manifest.KeyIdMismatch(expected~, actual~)) => {
      assert_eq(expected, pk.key_id())
      assert_eq(actual, wrong_id)
    }
    _ => abort("expected KeyIdMismatch on private key JSON")
  }

  // seed vs public_key mismatch in privkey JSON.
  let other_pk = @manifest.PrivateKey::from_seed(
      test_from_hex(
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
      ),
    )
    .unwrap()
    .public_key()
  let mismatched_sk = @utf8.encode(
    sk_str.replace(old=pk.to_hex(), new=other_pk.to_hex())[:],
  )
  match @manifest.PrivateKey::from_json_bytes(mismatched_sk) {
    Err(@manifest.InvalidPublicKey(..)) => ()
    _ => abort("expected InvalidPublicKey when seed and public_key mismatch")
  }

  // Uppercase seed, wrong hex lengths, non-object root, and nesting depth > 4.
  let upper_seed = @utf8.encode(
    sk_str.replace(old=test_to_hex(seed), new=test_to_hex(seed).to_upper())[:],
  )
  match @manifest.PrivateKey::from_json_bytes(upper_seed) {
    Err(@manifest.InvalidSchema(field="seed", ..)) => ()
    _ => abort("accepted uppercase seed hex")
  }
  let short_key_id = @utf8.encode(
    sig_str.replace(old=sig.key_id(), new="0000")[:],
  )
  match @manifest.ManifestSignature::from_json_bytes(short_key_id) {
    Err(@manifest.InvalidSchema(field="key_id", ..)) => ()
    _ => abort("accepted short key_id hex")
  }
  let upper_sha = @utf8.encode(
    sig_str.replace(
      old=sig.manifest_sha256(),
      new=sig.manifest_sha256().to_upper(),
    )[:],
  )
  match @manifest.ManifestSignature::from_json_bytes(upper_sha) {
    Err(@manifest.InvalidSchema(field="manifest_sha256", ..)) => ()
    _ => abort("accepted uppercase manifest_sha256 hex")
  }
  match @manifest.PublicKey::from_json_bytes(b"[]") {
    Err(@manifest.InvalidSchema(field="root", ..)) => ()
    _ => abort("accepted array root")
  }
  match
    @manifest.PublicKey::from_json_bytes(
      b"{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":1}}}}}",
    ) {
    Err(@manifest.InvalidJson(..)) => ()
    _ => abort("accepted JSON exceeding max_nesting_depth=4")
  }
}

///|
test "signature private key JSON parse error redacts secret characters and tokens" {
  // Distinctive hex seed starting with 'd' (InvalidChar when opening quote is removed).
  let seed_hex_alpha = "deadbeef0123456789abcdef0123456789abcdef0123456789abcdef01234567"
  let sk_alpha = @manifest.PrivateKey::from_seed(test_from_hex(seed_hex_alpha)).unwrap()
  let sk_alpha_str = test_utf8_decode(sk_alpha.to_json_bytes())
  let unquoted_alpha = @utf8.encode(
    sk_alpha_str.replace(
      old="\"seed\":\"\{seed_hex_alpha}\"",
      new="\"seed\":\{seed_hex_alpha}\"",
    )[:],
  )
  match @manifest.PrivateKey::from_json_bytes(unquoted_alpha) {
    Err(@manifest.InvalidJson(detail~, ..)) => {
      assert_true(detail.has_prefix("invalid character at line "))
      assert_false(detail.contains("'"))
      assert_false(detail.contains("deadbeef"))
      assert_false(detail.contains("d'"))
    }
    _ => abort("expected redacted InvalidJson on unquoted alpha seed")
  }

  // Distinctive hex seed starting with digits (InvalidNumber / InvalidChar when opening quote is removed).
  let seed_hex_num = "0123456789abcdefdeadbeef0123456789abcdef0123456789abcdef01234567"
  let sk_num = @manifest.PrivateKey::from_seed(test_from_hex(seed_hex_num)).unwrap()
  let sk_num_str = test_utf8_decode(sk_num.to_json_bytes())
  let unquoted_num = @utf8.encode(
    sk_num_str.replace(
      old="\"seed\":\"\{seed_hex_num}\"",
      new="\"seed\":\{seed_hex_num}\"",
    )[:],
  )
  match @manifest.PrivateKey::from_json_bytes(unquoted_num) {
    Err(@manifest.InvalidJson(detail~, ..)) => {
      assert_false(detail.contains("'"))
      assert_false(detail.contains("0123456789"))
      assert_false(detail.contains("deadbeef"))
      assert_true(
        detail.has_prefix("invalid number at line ") ||
        detail.has_prefix("invalid character at line "),
      )
    }
    _ => abort("expected redacted InvalidJson on unquoted numeric seed")
  }

  // Truncated and depth-exceeded private key JSON also emit redacted detail.
  match @manifest.PrivateKey::from_json_bytes(b"{\"seed\":\"deadbeef") {
    Err(@manifest.InvalidJson(detail~, ..)) => {
      assert_eq(detail, "unexpected end of input")
      assert_false(detail.contains("deadbeef"))
    }
    _ => abort("expected redacted InvalidJson on truncated private key JSON")
  }
  match
    @manifest.PrivateKey::from_json_bytes(
      b"{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":1}}}}}",
    ) {
    Err(@manifest.InvalidJson(detail~, ..)) =>
      assert_eq(detail, "nesting depth limit exceeded")
    _ => abort("expected redacted InvalidJson on over-nested private key JSON")
  }
}

///|
test "validate_manifest_schema prepare_signed and apply_signed" {
  // Large declared new.size_bytes > 128 MiB passes validate_manifest_schema.
  let large_manifest = @utf8.encode(
    ("{\"schema_version\":1,\"patch_format\":\"BSDIFF40\"," +
    "\"producer\":{\"name\":\"moonbsdiff\",\"version\":\"0.5.4\"}," +
    "\"old\":{\"size_bytes\":\"536870912\",\"sha256\":\"6bc14bdc4517a7a682c6910de2e2946eb8e1ecd04090728fef6d092a7ceb62c5\"}," +
    "\"new\":{\"size_bytes\":\"536870912\",\"sha256\":\"5719410b795aeecf690587cb18dfa92f4bc7c7c9c46662343faaa6dee218fa79\"}," +
    "\"patch\":{\"size_bytes\":\"1024\",\"sha256\":\"cd22b7f1c8031af0f84f610b967771311791007e33914b64d8ef81cfd58a7c6b\"}}\n")[:],
  )
  assert_eq(@manifest.validate_manifest_schema(large_manifest), Ok(()))

  // Invalid manifest fails validate_manifest_schema with ManifestError.
  assert_eq(
    @manifest.validate_manifest_schema(b"\xef\xbb\xbf" + large_manifest),
    Err(@manifest.InvalidEncoding),
  )

  // End-to-end diff -> sign -> prepare_signed -> apply_signed.
  let old = b"signed manifest baseline bytes 0123456789"
  let new = b"signed manifest upgraded bytes 0123456789!"
  let bundle = @manifest.diff(old, new, @moonbsdiff.Limits::for_diff()).unwrap()
  assert_eq(@manifest.validate_manifest_schema(bundle.manifest), Ok(()))

  let sk = @manifest.PrivateKey::from_seed(
    test_from_hex(
      "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
    ),
  ).unwrap()
  let pk = sk.public_key()
  let sig = sk.sign_manifest(bundle.manifest).unwrap()
  let apply_limits = @moonbsdiff.Limits::for_apply()

  let prepared = @manifest.prepare_signed(
    bundle.manifest,
    sig,
    pk,
    apply_limits,
  ).unwrap()
  assert_true(prepared.new == @manifest.ContentIdentity::of_bytes(new))
  assert_eq(
    @manifest.apply_signed(
      old,
      bundle.patch,
      bundle.manifest,
      sig,
      pk,
      apply_limits,
    ),
    Ok(new),
  )

  // Tampered manifest even with invalid JSON must fail Signature BEFORE Manifest parsing.
  match @manifest.prepare_signed(b"{bad json", sig, pk, apply_limits) {
    Err(@manifest.Signature(@manifest.ManifestHashMismatch(..))) => ()
    _ => abort("expected Signature(ManifestHashMismatch) before JSON parse")
  }

  // Valid signature but restricted limits fails with Manifest(LimitExceeded).
  let tight_limits = { ..apply_limits, max_new_bytes: 5L, }
  match
    @manifest.apply_signed(
      old,
      bundle.patch,
      bundle.manifest,
      sig,
      pk,
      tight_limits,
    ) {
    Err(
      @manifest.Manifest(
        @manifest.LimitExceeded(field="max_new_bytes", value=42L, limit=5L),
      ),
    ) => ()
    _ => abort("expected Manifest(LimitExceeded) for tight limits")
  }

  // Wrong key, wrong old bytes, wrong patch bytes in apply_signed & verify_manifest_signature_bytes.
  let wrong_pk = @manifest.PrivateKey::from_seed(
      test_from_hex(
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
      ),
    )
    .unwrap()
    .public_key()
  assert_eq(
    @manifest.apply_signed(
      old,
      bundle.patch,
      bundle.manifest,
      sig,
      wrong_pk,
      apply_limits,
    ),
    Err(
      @manifest.Signature(
        @manifest.KeyIdMismatch(expected=wrong_pk.key_id(), actual=pk.key_id()),
      ),
    ),
  )
  assert_eq(
    @manifest.apply_signed(
      b"wrong old bytes!",
      bundle.patch,
      bundle.manifest,
      sig,
      pk,
      apply_limits,
    ),
    Err(
      @manifest.Manifest(
        @manifest.IdentityMismatch(
          object=@manifest.Old,
          difference=@manifest.Size(
            expected=old.length().to_int64(),
            actual=16L,
          ),
        ),
      ),
    ),
  )
  assert_eq(
    @manifest.apply_signed(
      old,
      b"wrong patch",
      bundle.manifest,
      sig,
      pk,
      apply_limits,
    ),
    Err(
      @manifest.Manifest(
        @manifest.IdentityMismatch(
          object=@manifest.Patch,
          difference=@manifest.Size(
            expected=bundle.patch.length().to_int64(),
            actual=11L,
          ),
        ),
      ),
    ),
  )
  assert_eq(
    @manifest.verify_manifest_signature_bytes(
      bundle.manifest,
      sig.to_json_bytes(),
      wrong_pk.to_json_bytes(),
    ),
    Err(@manifest.KeyIdMismatch(expected=wrong_pk.key_id(), actual=pk.key_id())),
  )
  match
    @manifest.validate_manifest_schema(
      @utf8.encode(
        test_utf8_decode(large_manifest).replace(
          old="536870912",
          new="9223372036854775808",
        )[:],
      ),
    ) {
    Err(@manifest.InvalidSchema(field="old.size_bytes", ..)) => ()
    _ =>
      abort(
        "expected InvalidSchema for Int64 overflow in validate_manifest_schema",
      )
  }
}
