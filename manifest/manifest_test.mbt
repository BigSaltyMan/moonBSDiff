// Captured with manifest create on testdata/upstream/replace/{old,new,patch}.bin.
// The three identities and the CRC mutation hash were checked with Python hashlib.

///|
fn upstream_replace_patch() -> Bytes {
  b"\x42\x53\x44\x49\x46\x46\x34\x30\x2d\x00\x00\x00\x00\x00\x00\x00" +
  b"\x2b\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00" +
  b"\x42\x5a\x68\x39\x31\x41\x59\x26\x53\x59\x76\x72\x00\x7f\x00\x00" +
  b"\x05\xe0\x40\x50\x08\x04\x00\x40\x00\x20\x00\x30\xcd\x00\xc6\x81" +
  b"\x46\xc9\xb7\x17\x72\x45\x38\x50\x90\x76\x72\x00\x7f\x42\x5a\x68" +
  b"\x39\x31\x41\x59\x26\x53\x59\xab\x29\x89\x98\x00\x00\x00\x50\x00" +
  b"\x50\x80\x10\x00\x20\x00\x21\x21\xa0\xcd\x34\xce\x02\x8f\x17\x72" +
  b"\x45\x38\x50\x90\xab\x29\x89\x98\x42\x5a\x68\x39\x17\x72\x45\x38" +
  b"\x50\x90\x00\x00\x00\x00"
}

///|
fn upstream_replace_manifest() -> String {
  "{\"schema_version\":1" +
  ",\"patch_format\":\"BSDIFF40\"" +
  ",\"producer\":{\"name\":\"moonbsdiff\",\"version\":\"0.4.0\"}" +
  ",\"old\":{\"size_bytes\":\"20\",\"sha256\":\"6bc14bdc4517a7a682c6910de2e2946eb8e1ecd04090728fef6d092a7ceb62c5\"}" +
  ",\"new\":{\"size_bytes\":\"20\",\"sha256\":\"5719410b795aeecf690587cb18dfa92f4bc7c7c9c46662343faaa6dee218fa79\"}" +
  ",\"patch\":{\"size_bytes\":\"134\",\"sha256\":\"cd22b7f1c8031af0f84f610b967771311791007e33914b64d8ef81cfd58a7c6b\"}}" +
  "\n"
}

///|
fn restore_update(
  old : Bytes,
  patch : Bytes,
  trusted_manifest : Bytes,
) -> Result[Bytes, String] {
  match
    @manifest.apply(
      old,
      patch,
      trusted_manifest,
      @moonbsdiff.Limits::for_apply(),
    ) {
    Ok(restored) => Ok(restored)
    Err(IdentityMismatch(object=Old, ..)) =>
      Err("Installed bytes do not match the required old version")
    Err(error) => Err(@debug.to_string(error))
  }
}

///|
test "manifest public upstream replacement" {
  let document = upstream_replace_manifest()
  assert_eq(
    restore_update(
      b"0123456789abcdefghij",
      upstream_replace_patch(),
      @utf8.encode(document[:]),
    ),
    Ok(b"012345XYZ9abcdefghij"),
  )
}

///|
test "manifest public distinguishes identity and CRC failures" {
  let document = upstream_replace_manifest()
  let old = b"0123456789abcdefghij"
  let patch = upstream_replace_patch()
  let limits = @moonbsdiff.Limits::for_apply()
  let raw = @utf8.encode(document[:])
  assert_eq(
    @manifest.apply(b"!123456789abcdefghij", patch, raw, limits),
    Err(IdentityMismatch(object=Old, difference=Sha256)),
  )
  assert_eq(
    @manifest.apply(b"", patch, raw, limits),
    Err(IdentityMismatch(object=Old, difference=Size(expected=20L, actual=0L))),
  )
  assert_eq(
    restore_update(b"!123456789abcdefghij", patch, raw),
    Err("Installed bytes do not match the required old version"),
  )
  let wrong_target = document.replace(
    old="5719410b795aeecf690587cb18dfa92f4bc7c7c9c46662343faaa6dee218fa79",
    new="0000000000000000000000000000000000000000000000000000000000000000",
  )
  assert_eq(
    @manifest.apply(old, patch, @utf8.encode(wrong_target[:]), limits),
    Err(IdentityMismatch(object=Restored, difference=Sha256)),
  )
  // Flip a bit in the first Diff block CRC, with the new hash in the manifest.
  let damaged = patch[:87].to_owned() + b"\xaa" + patch[88:].to_owned()
  let crc_manifest = document.replace(
    old="cd22b7f1c8031af0f84f610b967771311791007e33914b64d8ef81cfd58a7c6b",
    new="3405a7369036a9d08132b27a74650db5552f687f2b3416d75be5e3a99f496756",
  )
  assert_eq(
    @manifest.apply(old, damaged, @utf8.encode(crc_manifest[:]), limits),
    Err(
      ApplyError({
        kind: DecompressionFailed,
        stage: Diff,
        block: Some("diff"),
        offset: None,
        field: Some("crc"),
        value: None,
        limit: None,
      }),
    ),
  )
}

///|
test "manifest public byte cap, strict keys, and declared limits" {
  let document = upstream_replace_manifest()
  let raw = @utf8.encode(document[:])
  let old = b"0123456789abcdefghij"
  let patch = upstream_replace_patch()
  let limits = @moonbsdiff.Limits::for_apply()
  // Invalid UTF-8 on purpose: the length check must precede decoding.
  let oversized = Bytes::from_array(Array::make(16385, b'\xff'))
  assert_eq(
    @manifest.apply(old, patch, oversized, limits),
    Err(LimitExceeded(field="max_manifest_bytes", value=16385L, limit=16384L)),
  )
  let duplicate = b"{\"\\u0073chema_version\":1," + raw[1:].to_owned()
  match @manifest.apply(old, patch, duplicate, limits) {
    Err(InvalidJson(field=Some("schema_version"), ..)) => ()
    _ => abort("escaped duplicate was not rejected by the JSON parser")
  }
  // Empty inputs assert that declarations are checked before the input identity.
  for
    (restricted, field, actual) in [
      ({ ..limits, max_old_bytes: 19L, }, "max_old_bytes", 20L),
      ({ ..limits, max_patch_bytes: 19L, }, "max_patch_bytes", 134L),
      ({ ..limits, max_new_bytes: 19L, }, "max_new_bytes", 20L),
      ({ ..limits, max_output_bytes: 19L, }, "max_output_bytes", 20L),
    ] {
    assert_eq(
      @manifest.apply(b"", b"", raw, restricted),
      Err(LimitExceeded(field~, value=actual, limit=19L)),
    )
  }
  assert_eq(
    @manifest.apply(old, patch, raw, limits),
    Ok(b"012345XYZ9abcdefghij"),
  )
}

///|
test "manifest public rejects UTF-8 BOM as InvalidEncoding" {
  let limits = @moonbsdiff.Limits::for_apply()
  let with_bom = b"\xef\xbb\xbf" + @utf8.encode(upstream_replace_manifest()[:])
  match @manifest.prepare(with_bom, limits) {
    Err(error) => assert_eq(error, @manifest.InvalidEncoding)
    Ok(_) => abort("UTF-8 BOM manifest was accepted by prepare")
  }
  match @manifest.prepare_target(with_bom, limits) {
    Err(error) => assert_eq(error, @manifest.InvalidEncoding)
    Ok(_) => abort("UTF-8 BOM manifest was accepted by prepare_target")
  }
}
