///|
fn sha256_hex(data : Bytes) -> String {
  let digest = @sha2.hash(data[:], kind=@sha2.Sha256)
  let hex = StringBuilder(size_hint=64)
  for byte in digest {
    hex.write_string(byte.to_hex())
  }
  hex.to_string()
}

///|
fn manifest_entry(data : Bytes) -> @json.Json {
  @json.Json::object({
    "size_bytes": @json.Json::string("\{data.length()}"),
    "sha256": @json.Json::string(sha256_hex(data)),
  })
}

///|
fn make_manifest(old : Bytes, new : Bytes, patch : Bytes) -> Bytes {
  let document = @json.Json::object({
    "schema_version": @json.Json::number(1.0),
    "patch_format": @json.Json::string("BSDIFF40"),
    "producer": @json.Json::object({
      "name": @json.Json::string("moonbsdiff"),
      "version": @json.Json::string(cli_version),
    }),
    "old": manifest_entry(old),
    "new": manifest_entry(new),
    "patch": manifest_entry(patch),
  })
  @utf8.encode((document.stringify() + "\n")[:])
}
