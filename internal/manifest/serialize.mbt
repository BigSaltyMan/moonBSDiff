///|
fn manifest_entry(size : Int64, hash : String) -> @json.Json {
  @json.Json::object({
    "size_bytes": @json.Json::string("\{size}"),
    "sha256": @json.Json::string(hash),
  })
}

///|
pub fn make_manifest(old : Bytes, new : Bytes, patch : Bytes) -> Bytes {
  make_manifest_with_old_identity(
    old.length().to_int64(),
    sha256_hex(old),
    new,
    patch,
  )
}

///|
pub fn make_manifest_with_old_identity(
  old_size : Int64,
  old_hash : String,
  new : Bytes,
  patch : Bytes,
) -> Bytes {
  let document = @json.Json::object({
    "schema_version": @json.Json::number(1.0),
    "patch_format": @json.Json::string("BSDIFF40"),
    "producer": @json.Json::object({
      "name": @json.Json::string("moonbsdiff"),
      "version": @json.Json::string(PRODUCER_VERSION),
    }),
    "old": manifest_entry(old_size, old_hash),
    "new": manifest_entry(new.length().to_int64(), sha256_hex(new)),
    "patch": manifest_entry(patch.length().to_int64(), sha256_hex(patch)),
  })
  @utf8.encode((document.stringify() + "\n")[:])
}
