///|
fn manifest_entry(data : Bytes) -> @json.Json {
  @json.Json::object({
    "size_bytes": @json.Json::string("\{data.length()}"),
    "sha256": @json.Json::string(sha256_hex(data)),
  })
}

///|
pub fn make_manifest(old : Bytes, new : Bytes, patch : Bytes) -> Bytes {
  let document = @json.Json::object({
    "schema_version": @json.Json::number(1.0),
    "patch_format": @json.Json::string("BSDIFF40"),
    "producer": @json.Json::object({
      "name": @json.Json::string("moonbsdiff"),
      "version": @json.Json::string(PRODUCER_VERSION),
    }),
    "old": manifest_entry(old),
    "new": manifest_entry(new),
    "patch": manifest_entry(patch),
  })
  @utf8.encode((document.stringify() + "\n")[:])
}
