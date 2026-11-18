///|
pub const MAX_MANIFEST_BYTES : Int32 = 16384

///|
pub fn digest_hex(digest : Bytes) -> String {
  let hex = StringBuilder(size_hint=64)
  for byte in digest {
    hex.write_string(byte.to_hex())
  }
  hex.to_string()
}

///|
pub fn sha256_hex(data : Bytes) -> String {
  digest_hex(@sha2.hash(data[:], kind=@sha2.Sha256))
}
