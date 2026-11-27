///|
pub let max_key_file_bytes : Int32 = 4096

///|
pub let max_signature_file_bytes : Int32 = 4096

///|
let signature_domain_prefix : Bytes = b"moonbsdiff-manifest-ed25519-v1\x00"

///|
/// Errors from parsing, formatting, or verifying detached Ed25519 signatures and keys.
#derive(Eq, Debug)
pub(all) enum SignatureError {
  InvalidKeyLength(expected~ : Int32, actual~ : Int32)
  InvalidPublicKey(detail~ : String)
  InvalidSignatureLength(expected~ : Int32, actual~ : Int32)
  InvalidSignatureFormat(detail~ : String)
  InvalidEncoding
  InvalidJson(field~ : String?, detail~ : String)
  InvalidSchema(field~ : String, detail~ : String)
  LimitExceeded(field~ : String, value~ : Int64, limit~ : Int64)
  KeyIdMismatch(expected~ : String, actual~ : String)
  ManifestHashMismatch(expected~ : String, actual~ : String)
  VerificationFailed
}

///|
pub extend SignatureError with Eq::{equal, not_equal}

///|
pub extend SignatureError with @debug.Debug::{to_repr}

///|
/// Errors from preparing or applying a signature-verified manifest bundle.
#derive(Eq, Debug)
pub(all) enum SignedManifestError {
  Signature(SignatureError)
  Manifest(ManifestError)
}

///|
pub extend SignedManifestError with Eq::{equal, not_equal}

///|
pub extend SignedManifestError with @debug.Debug::{to_repr}

///|
let ed25519_two_255 : BigInt = (1 : BigInt) << 255

///|
let ed25519_p : BigInt = ed25519_two_255 - 19

///|
let ed25519_d : BigInt = try! @string.parse_bigint(
  "37095705934669439343138083508754565189542113879843219016388785533085940283555",
)

///|
let ed25519_sqrt_m1 : BigInt = try! @string.parse_bigint(
  "19681161376707505956807079304988542015446066515923890162744021073123829784752",
)

///|
let ed25519_l : BigInt = ((1 : BigInt) << 252) +
  (try! @string.parse_bigint("27742317777372353535851937790883648493"))

///|
let ed25519_small_order_points : Array[String] = [
  "0100000000000000000000000000000000000000000000000000000000000000", "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
  "0000000000000000000000000000000000000000000000000000000000000000", "0000000000000000000000000000000000000000000000000000000000000080",
  "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a", "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa",
  "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05", "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85",
]

///|
fn le_bigint(bytes : BytesView) -> BigInt {
  let be : Array[Byte] = []
  for i = bytes.length() - 1; i >= 0; i = i - 1 {
    be.push(bytes[i])
  }
  BigInt::from_octets(Bytes::from_array(be)[:])
}

///|
fn ed25519_mod_p(a : BigInt) -> BigInt {
  let m = a % ed25519_p
  if m < (0 : BigInt) {
    m + ed25519_p
  } else {
    m
  }
}

///|
/// Enforce strict RFC 8032 canonical point encoding, curve membership,
/// canonical zero sign, and exclusion of all 8 small-order torsion points E[8].
fn validate_canonical_ed25519_point(raw : BytesView) -> Bool {
  if raw.length() != @ed25519.key_size {
    return false
  }
  let sign = (raw[31].to_int() >> 7) & 1
  let y = le_bigint(raw) % ed25519_two_255
  if y >= ed25519_p {
    return false
  }
  let yy = y * y % ed25519_p
  let u = ed25519_mod_p(yy - 1)
  let v = ed25519_mod_p(ed25519_d * yy + 1)
  if v == (0 : BigInt) {
    return false
  }
  let xx = ed25519_mod_p(u * v.pow(ed25519_p - 2, modulus=ed25519_p))
  let mut x = xx.pow((ed25519_p + 3) / 8, modulus=ed25519_p)
  if ed25519_mod_p(x * x - xx) != (0 : BigInt) {
    x = ed25519_mod_p(x * ed25519_sqrt_m1)
    if ed25519_mod_p(x * x - xx) != (0 : BigInt) {
      return false
    }
  }
  if x == (0 : BigInt) && sign == 1 {
    return false
  }
  let hex = @manifest_support.digest_hex(raw.to_owned())
  !ed25519_small_order_points.contains(hex)
}

///|
fn validate_raw_signature_format(
  sig : BytesView,
) -> Result[Unit, SignatureError] {
  if sig.length() != @ed25519.sig_size {
    return Err(
      InvalidSignatureLength(expected=@ed25519.sig_size, actual=sig.length()),
    )
  }
  if !validate_canonical_ed25519_point(sig[0:32]) {
    return Err(
      InvalidSignatureFormat(detail="invalid or non-canonical Ed25519 R point"),
    )
  }
  if le_bigint(sig[32:64]) >= ed25519_l {
    return Err(InvalidSignatureFormat(detail="Ed25519 signature scalar S >= L"))
  }
  Ok(())
}

///|
fn check_manifest_size_limit(
  manifest_bytes : Bytes,
) -> Result[Unit, SignatureError] {
  let size = manifest_bytes.length().to_int64()
  let limit = @manifest_support.MAX_MANIFEST_BYTES.to_int64()
  if size > limit {
    return Err(LimitExceeded(field="max_manifest_bytes", value=size, limit~))
  }
  Ok(())
}

///|
fn hex_nibble(byte : Byte) -> Int32? {
  let code = byte.to_int()
  if code >= 48 && code <= 57 {
    Some(code - 48)
  } else if code >= 97 && code <= 102 {
    Some(code - 97 + 10)
  } else {
    None
  }
}

///|
fn envelope_string(
  value : @json.Json,
  field : String,
) -> Result[String, SignatureError] {
  match value {
    @json.String(text) => Ok(text)
    _ =>
      Err(
        InvalidSchema(
          field~,
          detail="signature envelope: " + field + " must be a string",
        ),
      )
  }
}

///|
fn parse_lowercase_hex(
  value : @json.Json,
  field : String,
  expected_hex_len : Int32,
) -> Result[(String, Bytes), SignatureError] {
  let text = match envelope_string(value, field) {
    Ok(s) => s
    Err(err) => return Err(err)
  }
  let encoded = @utf8.encode(text[:])
  if encoded.length() != expected_hex_len {
    return Err(
      InvalidSchema(
        field~,
        detail="signature envelope: " +
          field +
          " requires \{expected_hex_len} lowercase hex digits",
      ),
    )
  }
  let out : Array[Byte] = []
  let mut i = 0
  while i < encoded.length() {
    let hi = match hex_nibble(encoded[i]) {
      Some(v) => v
      None =>
        return Err(
          InvalidSchema(
            field~,
            detail="signature envelope: " +
              field +
              " requires lowercase hex digits",
          ),
        )
    }
    let lo = match hex_nibble(encoded[i + 1]) {
      Some(v) => v
      None =>
        return Err(
          InvalidSchema(
            field~,
            detail="signature envelope: " +
              field +
              " requires lowercase hex digits",
          ),
        )
    }
    out.push(((hi << 4) | lo).to_byte())
    i = i + 2
  }
  Ok((text, Bytes::from_array(out)))
}

///|
fn parse_signature_envelope(
  data : Bytes,
  limit : Int32,
  limit_field : String,
  required_keys : Array[String],
  expected_format : String,
  redact_detail~ : Bool = false,
) -> Result[Map[String, @json.Json], SignatureError] {
  let size = data.length().to_int64()
  let max_bytes = limit.to_int64()
  if size > max_bytes {
    return Err(LimitExceeded(field=limit_field, value=size, limit=max_bytes))
  }
  if data is [0xef, 0xbb, 0xbf, ..] {
    return Err(InvalidEncoding)
  }
  let text = @utf8.decode(data[:], ignore_bom=false) catch {
    _ => return Err(InvalidEncoding)
  }
  if json_exceeds_max_depth(text[:], 4) {
    return Err(InvalidJson(field=None, detail="nesting depth limit exceeded"))
  }
  let json = @json.parse(
    text[:],
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    error => {
      let field = json_duplicate_key_field(error)
      let detail = if redact_detail {
        json_format_redacted_parse_error(error)
      } else {
        @debug.to_string(error)
      }
      return Err(InvalidJson(field~, detail~))
    }
  }
  let fields = match json {
    @json.Object(fields) => fields
    _ =>
      return Err(
        InvalidSchema(
          field="root",
          detail="signature envelope: root must be an object",
        ),
      )
  }
  for key in required_keys {
    if fields.get(key) is None {
      return Err(
        InvalidSchema(field=key, detail="signature envelope: missing " + key),
      )
    }
  }
  for key, _ in fields {
    if !required_keys.contains(key) {
      return Err(
        InvalidSchema(
          field=key,
          detail="signature envelope: unknown field " + key,
        ),
      )
    }
  }
  if !(fields["schema_version"] is @json.Number(_, repr=Some("1"))) {
    return Err(
      InvalidSchema(
        field="schema_version",
        detail="signature envelope: expected integer 1",
      ),
    )
  }
  let format = match envelope_string(fields["format"], "format") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if format != expected_format {
    return Err(
      InvalidSchema(
        field="format",
        detail="signature envelope: expected format " + expected_format,
      ),
    )
  }
  let algorithm = match envelope_string(fields["algorithm"], "algorithm") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if algorithm != "ed25519" {
    return Err(
      InvalidSchema(
        field="algorithm",
        detail="signature envelope: only ed25519 is supported",
      ),
    )
  }
  Ok(fields)
}

///|
fn encode_envelope_json(fields : Map[String, @json.Json]) -> Bytes {
  let document = @json.Json::object(fields)
  @utf8.encode((document.stringify() + "\n")[:])
}

///|
/// Verified canonical Ed25519 public key (non-torsion, on-curve, canonical encoding).
#derive(Eq, Debug)
pub struct PublicKey {
  priv raw : Bytes
  priv hex : String
  priv key_id : String
}

///|
pub extend PublicKey with Eq::{equal, not_equal}

///|
pub extend PublicKey with @debug.Debug::{to_repr}

///|
/// Construct a PublicKey from 32 raw compressed Edwards25519 bytes.
pub fn PublicKey::from_bytes(raw : Bytes) -> Result[PublicKey, SignatureError] {
  if raw.length() != @ed25519.key_size {
    return Err(
      InvalidKeyLength(expected=@ed25519.key_size, actual=raw.length()),
    )
  }
  if !validate_canonical_ed25519_point(raw[:]) {
    return Err(
      InvalidPublicKey(
        detail="invalid, non-canonical, off-curve, or small-order Ed25519 public key",
      ),
    )
  }
  let ed_pk = @ed25519.PublicKey::new(raw[:]) catch {
    @spec.Size(want~, got~) =>
      return Err(InvalidKeyLength(expected=want, actual=got))
    @spec.Tag | @spec.Weak =>
      return Err(InvalidPublicKey(detail="invalid Ed25519 public key"))
  }
  let canonical = ed_pk.bytes()
  let hex = @manifest_support.digest_hex(canonical)
  let key_id = @manifest_support.sha256_hex(canonical)[:16].to_owned()
  Ok({ raw: canonical, hex, key_id, })
}

///|
/// Parse a strict schema-1 Ed25519 public key JSON envelope.
pub fn PublicKey::from_json_bytes(
  data : Bytes,
) -> Result[PublicKey, SignatureError] {
  let fields = match
    parse_signature_envelope(
      data,
      max_key_file_bytes,
      "max_key_file_bytes",
      ["schema_version", "format", "algorithm", "public_key", "key_id"],
      "moonbsdiff-ed25519-public-key",
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (_, pub_bytes) = match
    parse_lowercase_hex(fields["public_key"], "public_key", 64) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (json_key_id, _) = match
    parse_lowercase_hex(fields["key_id"], "key_id", 16) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let pk = match PublicKey::from_bytes(pub_bytes) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if json_key_id != pk.key_id {
    return Err(KeyIdMismatch(expected=pk.key_id, actual=json_key_id))
  }
  Ok(pk)
}

///|
pub fn PublicKey::to_bytes(self : PublicKey) -> Bytes {
  self.raw
}

///|
pub fn PublicKey::to_hex(self : PublicKey) -> String {
  self.hex
}

///|
pub fn PublicKey::key_id(self : PublicKey) -> String {
  self.key_id
}

///|
pub fn PublicKey::to_json_bytes(self : PublicKey) -> Bytes {
  encode_envelope_json({
    "schema_version": @json.Json::number(1.0),
    "format": @json.Json::string("moonbsdiff-ed25519-public-key"),
    "algorithm": @json.Json::string("ed25519"),
    "public_key": @json.Json::string(self.hex),
    "key_id": @json.Json::string(self.key_id),
  })
}

///|
/// Ed25519 signing key holding a 32-byte seed. Intentionally omits Debug/Show
/// so secret seed bytes are never formatted or leaked.
pub struct PrivateKey {
  priv inner : @ed25519.PrivateKey
  priv pub_key : PublicKey
}

///|
/// Construct a PrivateKey from its exact 32-byte RFC 8032 seed.
pub fn PrivateKey::from_seed(
  seed : Bytes,
) -> Result[PrivateKey, SignatureError] {
  if seed.length() != @ed25519.key_size {
    return Err(
      InvalidKeyLength(expected=@ed25519.key_size, actual=seed.length()),
    )
  }
  let inner = @ed25519.PrivateKey::new(seed[:]) catch {
    @spec.Size(want~, got~) =>
      return Err(InvalidKeyLength(expected=want, actual=got))
    @spec.Tag | @spec.Weak =>
      return Err(InvalidPublicKey(detail="invalid Ed25519 seed"))
  }
  let pub_key = match PublicKey::from_bytes(inner.public().bytes()) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok({ inner, pub_key, })
}

///|
/// Parse a strict schema-1 Ed25519 private key JSON envelope and cross-check
/// derived public_key and key_id against seed.
pub fn PrivateKey::from_json_bytes(
  data : Bytes,
) -> Result[PrivateKey, SignatureError] {
  let fields = match
    parse_signature_envelope(
      data,
      max_key_file_bytes,
      "max_key_file_bytes",
      ["schema_version", "format", "algorithm", "seed", "public_key", "key_id"],
      "moonbsdiff-ed25519-private-key",
      redact_detail=true,
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (_, seed_bytes) = match parse_lowercase_hex(fields["seed"], "seed", 64) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (_, pub_bytes) = match
    parse_lowercase_hex(fields["public_key"], "public_key", 64) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (json_key_id, _) = match
    parse_lowercase_hex(fields["key_id"], "key_id", 16) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let sk = match PrivateKey::from_seed(seed_bytes) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let declared_pub = match PublicKey::from_bytes(pub_bytes) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if declared_pub != sk.pub_key {
    return Err(
      InvalidPublicKey(
        detail="private key envelope public_key does not match seed",
      ),
    )
  }
  if json_key_id != sk.pub_key.key_id {
    return Err(KeyIdMismatch(expected=sk.pub_key.key_id, actual=json_key_id))
  }
  Ok(sk)
}

///|
pub fn PrivateKey::public_key(self : PrivateKey) -> PublicKey {
  self.pub_key
}

///|
pub fn PrivateKey::key_id(self : PrivateKey) -> String {
  self.pub_key.key_id
}

///|
pub fn PrivateKey::to_json_bytes(self : PrivateKey) -> Bytes {
  encode_envelope_json({
    "schema_version": @json.Json::number(1.0),
    "format": @json.Json::string("moonbsdiff-ed25519-private-key"),
    "algorithm": @json.Json::string("ed25519"),
    "seed": @json.Json::string(@manifest_support.digest_hex(self.inner.bytes())),
    "public_key": @json.Json::string(self.pub_key.hex),
    "key_id": @json.Json::string(self.pub_key.key_id),
  })
}

///|
/// Sign exact manifest bytes using domain-separated Ed25519.
pub fn PrivateKey::sign_manifest(
  self : PrivateKey,
  manifest_bytes : Bytes,
) -> Result[ManifestSignature, SignatureError] {
  match check_manifest_size_limit(manifest_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  let payload = signature_domain_prefix + manifest_bytes
  let sig_raw = @spec.Signer::sign(self.inner, payload[:])
  match validate_raw_signature_format(sig_raw[:]) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok({
    key_id: self.pub_key.key_id,
    manifest_sha256: @manifest_support.sha256_hex(manifest_bytes),
    signature_raw: sig_raw,
    signature_hex: @manifest_support.digest_hex(sig_raw),
  })
}

///|
/// Detached domain-separated Ed25519 signature over a manifest JSON document.
#derive(Eq, Debug)
pub struct ManifestSignature {
  priv key_id : String
  priv manifest_sha256 : String
  priv signature_raw : Bytes
  priv signature_hex : String
}

///|
pub extend ManifestSignature with Eq::{equal, not_equal}

///|
pub extend ManifestSignature with @debug.Debug::{to_repr}

///|
/// Parse a strict schema-1 detached manifest signature JSON envelope.
pub fn ManifestSignature::from_json_bytes(
  data : Bytes,
) -> Result[ManifestSignature, SignatureError] {
  let fields = match
    parse_signature_envelope(
      data,
      max_signature_file_bytes,
      "max_signature_file_bytes",
      [
        "schema_version", "format", "algorithm", "key_id", "manifest_sha256", "signature",
      ],
      "moonbsdiff-manifest-signature",
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (key_id, _) = match parse_lowercase_hex(fields["key_id"], "key_id", 16) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (manifest_sha256, _) = match
    parse_lowercase_hex(fields["manifest_sha256"], "manifest_sha256", 64) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (signature_hex, signature_raw) = match
    parse_lowercase_hex(fields["signature"], "signature", 128) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match validate_raw_signature_format(signature_raw[:]) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok({ key_id, manifest_sha256, signature_raw, signature_hex, })
}

///|
pub fn ManifestSignature::to_json_bytes(self : ManifestSignature) -> Bytes {
  encode_envelope_json({
    "schema_version": @json.Json::number(1.0),
    "format": @json.Json::string("moonbsdiff-manifest-signature"),
    "algorithm": @json.Json::string("ed25519"),
    "key_id": @json.Json::string(self.key_id),
    "manifest_sha256": @json.Json::string(self.manifest_sha256),
    "signature": @json.Json::string(self.signature_hex),
  })
}

///|
pub fn ManifestSignature::signature_bytes(self : ManifestSignature) -> Bytes {
  self.signature_raw
}

///|
pub fn ManifestSignature::signature_hex(self : ManifestSignature) -> String {
  self.signature_hex
}

///|
pub fn ManifestSignature::key_id(self : ManifestSignature) -> String {
  self.key_id
}

///|
pub fn ManifestSignature::manifest_sha256(self : ManifestSignature) -> String {
  self.manifest_sha256
}

///|
/// Verify a 64-byte raw Ed25519 signature over domain-separated manifest bytes.
pub fn verify_raw_signature(
  manifest_bytes : Bytes,
  sig_bytes : Bytes,
  public_key : PublicKey,
) -> Result[Unit, SignatureError] {
  match check_manifest_size_limit(manifest_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  match validate_raw_signature_format(sig_bytes[:]) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if !validate_canonical_ed25519_point(public_key.raw[:]) {
    return Err(
      InvalidPublicKey(
        detail="invalid, non-canonical, off-curve, or small-order Ed25519 public key",
      ),
    )
  }
  let ed_pk = @ed25519.PublicKey::new(public_key.raw[:]) catch {
    @spec.Size(want~, got~) =>
      return Err(InvalidKeyLength(expected=want, actual=got))
    @spec.Tag | @spec.Weak =>
      return Err(InvalidPublicKey(detail="invalid Ed25519 public key"))
  }
  let payload = signature_domain_prefix + manifest_bytes
  if @spec.Verifier::verify(ed_pk, payload[:], sig_bytes[:]) {
    Ok(())
  } else {
    Err(VerificationFailed)
  }
}

///|
/// Verify a structured detached ManifestSignature against manifest_bytes and public_key.
pub fn verify_manifest_signature(
  manifest_bytes : Bytes,
  signature : ManifestSignature,
  public_key : PublicKey,
) -> Result[Unit, SignatureError] {
  match check_manifest_size_limit(manifest_bytes) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  if signature.key_id != public_key.key_id {
    return Err(
      KeyIdMismatch(expected=public_key.key_id, actual=signature.key_id),
    )
  }
  let actual_hash = @manifest_support.sha256_hex(manifest_bytes)
  if actual_hash != signature.manifest_sha256 {
    return Err(
      ManifestHashMismatch(
        expected=signature.manifest_sha256,
        actual=actual_hash,
      ),
    )
  }
  verify_raw_signature(manifest_bytes, signature.signature_raw, public_key)
}

///|
/// Parse public key JSON and detached signature JSON envelopes, then verify manifest_bytes.
pub fn verify_manifest_signature_bytes(
  manifest_bytes : Bytes,
  signature_json : Bytes,
  public_key_json : Bytes,
) -> Result[ManifestSignature, SignatureError] {
  let public_key = match PublicKey::from_json_bytes(public_key_json) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let signature = match ManifestSignature::from_json_bytes(signature_json) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match verify_manifest_signature(manifest_bytes, signature, public_key) {
    Ok(_) => Ok(signature)
    Err(err) => Err(err)
  }
}

///|
/// Validate schema-1 manifest structure without applying size-limit caps on declared
/// old/new/patch byte sizes.
pub fn validate_manifest_schema(
  manifest_bytes : Bytes,
) -> Result[Unit, ManifestError] {
  try {
    parse_bounded_manifest(manifest_bytes, @moonbsdiff.Limits::for_apply())
    |> ignore
    Ok(())
  } catch {
    Rejected(error) => Err(error)
  }
}

///|
/// Verify the detached manifest signature first, then parse and preflight the manifest.
pub fn prepare_signed(
  manifest_bytes : Bytes,
  signature : ManifestSignature,
  public_key : PublicKey,
  limits : @moonbsdiff.Limits,
) -> Result[PreparedManifest, SignedManifestError] {
  match verify_manifest_signature(manifest_bytes, signature, public_key) {
    Ok(_) => ()
    Err(err) => return Err(Signature(err))
  }
  match prepare(manifest_bytes, limits) {
    Ok(prepared) => Ok(prepared)
    Err(err) => Err(Manifest(err))
  }
}

///|
/// Verify the detached manifest signature first, then prepare and apply the patch.
pub fn apply_signed(
  old_bytes : Bytes,
  patch_bytes : Bytes,
  manifest_bytes : Bytes,
  signature : ManifestSignature,
  public_key : PublicKey,
  limits : @moonbsdiff.Limits,
) -> Result[Bytes, SignedManifestError] {
  let prepared = match
    prepare_signed(manifest_bytes, signature, public_key, limits) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  match prepared.restore(old_bytes, patch_bytes) {
    Ok(restored) => Ok(restored)
    Err(err) => Err(Manifest(err))
  }
}
