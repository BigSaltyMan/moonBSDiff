# Multi-key trust stores and signed release catalogs

MoonBSDiff **0.7.0** adds multi-key Ed25519 trust stores (`TrustStore`), fail-closed batch verification of signed candidate manifests (`verify_signed_candidates`), Schema 1 signed release catalogs (`ReleaseCatalog`, `CatalogSignature`), anti-replay enforcement (`min_catalog_version`), and anti-downgrade multi-hop update planning (`VerifiedCatalog::plan_update`).

All types and functions live in `BigSaltyMan/moonbsdiff/manifest` and run identically across **native, JS, and Wasm-GC**. They build on the single-file manifest and RFC 8032 Ed25519 verification layer documented in [manifest.md](manifest.md).

## Multi-key `TrustStore` and key rotation

`TrustStore` pins one or more trusted Ed25519 `PublicKey` values so clients can rotate signing keys without downtime.

```moonbit
pub fn TrustStore::from_keys(Array[PublicKey]) -> Result[TrustStore, SignatureError]
pub fn TrustStore::len(Self) -> Int32
pub fn TrustStore::key_ids(Self) -> ReadOnlyArray[String]
pub fn TrustStore::find(Self, String) -> PublicKey?
pub fn TrustStore::verify_manifest_signature(Self, Bytes, ManifestSignature) -> Result[PublicKey, SignatureError]
pub fn TrustStore::verify_catalog(Self, Bytes, CatalogSignature, min_catalog_version? : Int64) -> Result[VerifiedCatalog, CatalogError]
```

### Construction invariants (`TrustStore::from_keys`)

- **Non-empty**: Passing an empty array fails closed with `InvalidSchema(field="keys", ...)`.
- **Strict RFC 8032 validation**: Every key is checked for canonical Edwards25519 point encoding, curve membership, canonical zero sign, and exclusion of all 8 small-order torsion points `E[8]` (`InvalidPublicKey`).
- **Deduplication**: Identical keys are deduplicated while preserving first-seen `key_id` order (`key_id` is the first 16 lowercase hex digits of `SHA-256(raw_public_key)`).
- **Conflict rejection**: Two *distinct* raw public keys sharing the same `key_id` are rejected with `InvalidPublicKey`.

### Zero-downtime rotation lifecycle

1. **Baseline**: Clients pin `TrustStore::from_keys([pk_old])`; publisher signs with `sk_old`.
2. **Overlap window**: Clients upgrade to `TrustStore::from_keys([pk_old, pk_new])`; publisher switches to signing new releases with `sk_new` while existing `sk_old` signatures continue to verify. `verify_manifest_signature` returns the matching `PublicKey`, and `verify_catalog` records `signer_key_id`.
3. **Retirement**: Clients drop the retired key and pin `TrustStore::from_keys([pk_new])`; signatures produced by `sk_old` now fail closed with `KeyIdMismatch`.

When `sig.key_id()` is not present in the store, `verify_manifest_signature` and `verify_catalog` return `KeyIdMismatch(expected="<comma-joined pinned key_ids>", actual=sig.key_id)`.

## Batch signed candidate verification (`verify_signed_candidates`)

```moonbit
pub fn verify_signed_candidates(
  TrustStore,
  Array[(Bytes, ManifestSignature)],
  @moonbsdiff.Limits,
) -> Result[Array[PreparedManifest], SignedCandidateError]
```

```moonbit
pub(all) enum SignedCandidateError {
  InvalidLimits(@moonbsdiff.BsdiffError)
  Signature(index~ : Int32, error~ : SignatureError)
  Manifest(index~ : Int32, error~ : ManifestError)
}
```

`verify_signed_candidates` validates `limits` first, then enforces a strict **two-pass, verify-before-parse** policy across the entire candidate list:

1. **Preflight (`limits.validate()`)**: Fails closed immediately with `InvalidLimits(err)` if `limits` is invalid — even when `candidates` is empty.
2. **Pass 1 (authentication)**: Calls `store.verify_manifest_signature(manifest_bytes, sig)` on *every* candidate before parsing or preparing *any* manifest JSON. If candidate `i` fails size bounds (`16 KiB`), `key_id` lookup, `manifest_sha256`, or Ed25519 verification, the call fails closed immediately with `Signature(index=i, error~)`.
3. **Pass 2 (preparation)**: Only after all signatures pass does it call `prepare(manifest_bytes, limits)` on each candidate in order, failing with `Manifest(index=i, error~)` on the first schema or `Limits` violation.

The returned `Array[PreparedManifest]` can be passed directly to `plan` or `plan_update`.

## Schema 1 `ReleaseCatalog`

A `ReleaseCatalog` describes a release channel, its monotonic `catalog_version`, its anti-downgrade floor `min_version`, the set of known releases (`CatalogRelease`), and the directed patch graph (`CatalogPatch`).

### Constants and structural bounds

| Bound | Value | Error on violation |
| --- | --- | --- |
| `max_catalog_file_bytes` (public `Int32`) | `262144` (256 KiB; enforced by both `from_json_bytes` and `ReleaseCatalog::new`) | `LimitExceeded(field="max_catalog_file_bytes", ...)` |
| Max releases per catalog | `4096` | `LimitExceeded(field="max_catalog_releases", ...)` |
| Max patches per catalog | `16384` | `LimitExceeded(field="max_catalog_patches", ...)` |
| `channel` length & charset | `1..64` ASCII `[A-Za-z0-9._-]`, no unpaired UTF-16 surrogates | `InvalidSchema(field="channel", ...)` |
| `releases[i].label` | `1..64` UTF-8 bytes, no unpaired UTF-16 surrogates, no control chars (`0x00..0x1f`, `0x7f..0x9f`), unique | `InvalidSchema` |
| `patches[i].patch_size_bytes` | `>= 32` (minimum BSDIFF40 header) | `InvalidSchema` |
| `patches[i].uri` (optional) | `1..512` UTF-8 bytes, strict `http://`/`https://` URL or relative POSIX path (details below) | `InvalidSchema` |

Hardened `patches[i].uri` validation rules (enforced identically in `ReleaseCatalog::new` and `ReleaseCatalog::from_json_bytes`):

- Rejects empty strings, `> 512` UTF-8 bytes, and unpaired UTF-16 surrogates.
- Rejects ASCII control bytes (`< 0x20`, `0x7F`), UTF-8 C1 control characters (`U+0080..U+009F` / `0xC2 0x80..0x9F`), Unicode invisible/whitespace/bidi/line-separator/BOM characters, NFKC dot/slash/colon confusables, and backslashes (`\`) in both raw bytes and every percent-decoded pass.
- Enforces strict UTF-8 (`ignore_bom=false`) on every percent-decoded pass (blocking raw C1 bytes and overlong encodings such as `%c0%ae` / `%c0%af`), iterates percent-decoding to a fixed point (bounded at 4 passes; rejects URIs still changing after 4 passes), and rejects `..` traversal segments across `/`, `\`, `?`, `#`, and `;` delimiters at every pass.
- Allows **only** two URI forms (blocking absolute paths like `/etc/passwd`, Windows drive/UNC paths, and `file://` URIs):
  - **`http://` or `https://` URLs**: rejects whitespace and metacharacters (` `, `<`, `>`, `"`, `` ` ``, `{`, `}`, `|`, `^`) and enforces strict RFC 3986 ASCII `host[:port]` authority on both raw and decoded bytes — valid DNS hostname (`1..253` ASCII chars, labels `1..63` `[A-Za-z0-9-]`), valid IPv4, or valid `[IPv6]` literal with optional port `1..65535` (rejecting userinfo `@`, `%`, non-ASCII, and metacharacters).
  - **Strict relative POSIX paths**: no leading or trailing `/`, no whitespace (`<= 0x20`), `?`, `#`, `:`, or `\`, no invisible/confusable characters, and no empty, `.`, or `..` segments on both raw and decoded bytes.

### Types and methods

```moonbit
pub(all) struct CatalogRelease {
  version : Int64
  label : String
  content : ContentIdentity
}

pub(all) struct CatalogPatch {
  from_version : Int64
  to_version : Int64
  patch : ContentIdentity
  manifest_sha256 : String?
  uri : String?
}

pub struct ReleaseCatalog {
  channel : String
  catalog_version : Int64
  min_version : Int64
  releases : ReadOnlyArray[CatalogRelease]
  patches : ReadOnlyArray[CatalogPatch]
}

pub fn ReleaseCatalog::new(
  String,
  Int64,
  Int64,
  Array[CatalogRelease],
  Array[CatalogPatch],
) -> Result[ReleaseCatalog, CatalogError]

pub fn ReleaseCatalog::from_json_bytes(Bytes) -> Result[ReleaseCatalog, CatalogError]
pub fn ReleaseCatalog::to_json_bytes(Self) -> Bytes
```

### Canonical Schema 1 JSON format

`ReleaseCatalog::to_json_bytes` emits deterministic compact UTF-8 JSON with exact 64-bit integer formatting and a single trailing `\n` (pretty-printed below for readability):

```json
{
  "schema": 1,
  "type": "moonbsdiff-release-catalog",
  "channel": "stable",
  "catalog_version": 42,
  "min_version": 2,
  "releases": [
    {
      "version": 1,
      "label": "1.0.0",
      "size_bytes": 1048576,
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    },
    {
      "version": 2,
      "label": "2.0.0",
      "size_bytes": 1052672,
      "sha256": "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    }
  ],
  "patches": [
    {
      "from_version": 1,
      "to_version": 2,
      "patch_size_bytes": 4096,
      "patch_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "manifest_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "uri": "patches/v1-to-v2.patch"
    }
  ]
}
```

Strict parsing rules in `ReleaseCatalog::from_json_bytes`:

- Rejects size `> max_catalog_file_bytes`, leading UTF-8 BOM (`0xEF 0xBB 0xBF`), and invalid UTF-8 (`InvalidEncoding`).
- Parses JSON with `max_nesting_depth = 8`, `reject_duplicate_keys = true`, and `preserve_number_repr = true`; rejects unknown or missing fields at every object level.
- All integer fields (`catalog_version`, `min_version`, `version`, `size_bytes`, `from_version`, `to_version`, `patch_size_bytes`) are parsed directly from their exact base-10 integer tokens (no floating-point conversion, no leading zeros, no fractions/exponents, overflow-checked against `Int64::max`).
- Requires `schema == 1`, `type == "moonbsdiff-release-catalog"`, `catalog_version >= 1`, `min_version >= 0`, non-empty `releases` with unique `version >= 1` and unique `label`, every `sha256` / `patch_sha256` / optional `manifest_sha256` as 64 lowercase hex digits, and every patch edge referencing distinct versions present in `releases` (`from_version != to_version`).

## `CatalogSignature`, domain separation, and `min_catalog_version` anti-replay

```moonbit
pub fn PrivateKey::sign_catalog(Self, Bytes) -> Result[CatalogSignature, CatalogError]
pub fn CatalogSignature::from_json_bytes(Bytes) -> Result[Self, SignatureError]
pub fn CatalogSignature::to_json_bytes(Self) -> Bytes
pub fn CatalogSignature::key_id(Self) -> String
pub fn CatalogSignature::catalog_sha256(Self) -> String
pub fn CatalogSignature::signature_bytes(Self) -> Bytes
pub fn CatalogSignature::signature_hex(Self) -> String
```

### Domain separation

`PrivateKey::sign_catalog` validates `catalog_bytes` against Schema 1 first, then computes an RFC 8032 Ed25519 signature over:

```text
b"moonbsdiff-catalog-ed25519-v1\x00" || catalog_bytes
```

Every MoonBSDiff v1 signed artifact uses a distinct NUL-terminated domain prefix so a signature created for one artifact type can never verify as another, even under the same keypair:

| Artifact | Domain separation prefix | Detached envelope discriminator |
| --- | --- | --- |
| Single-file manifest ([manifest.md](manifest.md)) | `moonbsdiff-manifest-ed25519-v1\x00` | `schema_version: 1`, `format: "moonbsdiff-manifest-signature"` |
| Release catalog (this doc) | `moonbsdiff-catalog-ed25519-v1\x00` | `schema_version: 1`, `format: "moonbsdiff-catalog-signature"` |
| Directory manifest ([dir-delta.md](dir-delta.md)) | `moonbsdiff-dir-manifest-ed25519-v1\x00` | `schema: 1`, `type: "moonbsdiff-dir-manifest-signature"` |

### Detached `CatalogSignature` JSON envelope

Capped at `max_signature_file_bytes` (`4096` bytes), `max_nesting_depth = 4`, no BOM, no duplicate or unknown keys:

```json
{
  "schema_version": 1,
  "format": "moonbsdiff-catalog-signature",
  "algorithm": "ed25519",
  "key_id": "0123456789abcdef",
  "catalog_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "signature": "<128 lowercase hex digits>"
}
```

### Verification and anti-replay (`TrustStore::verify_catalog`)

`TrustStore::verify_catalog(catalog_bytes, sig, min_catalog_version?)` executes in strict **verify-before-parse** order:

1. Enforces `catalog_bytes.length() <= max_catalog_file_bytes` (`LimitExceeded`).
2. Looks up `sig.key_id()` in the `TrustStore` (`Signature(KeyIdMismatch(...))`).
3. Verifies `SHA-256(catalog_bytes) == sig.catalog_sha256()` (`CatalogHashMismatch`).
4. Verifies strict RFC 8032 signature format (`R` canonical non-torsion, `S < L`) and Ed25519 signature over `b"moonbsdiff-catalog-ed25519-v1\x00" + catalog_bytes` (`Signature(...)`).
5. **Only after authentication succeeds**, parses and validates `ReleaseCatalog::from_json_bytes(catalog_bytes)`.
6. **Anti-replay check**: If `min_catalog_version` is `Some(min_ver)` and `catalog.catalog_version < min_ver`, fails closed with `CatalogRollback(catalog_version~, min_catalog_version~)`. Clients should persist the highest verified `catalog.catalog_version` monotonically and pass it on every subsequent update check to defeat catalog replay/freeze attacks.
7. Returns the proof-carrying `VerifiedCatalog`:

```moonbit
pub struct VerifiedCatalog {
  catalog : ReleaseCatalog
  catalog_sha256 : String
  signer_key_id : String
}
```

## Anti-downgrade routing (`VerifiedCatalog::plan_update`)

Only a `VerifiedCatalog` exposes `plan_update`, ensuring routing decisions cannot run on unauthenticated catalog bytes:

```moonbit
pub fn VerifiedCatalog::plan_update(
  Self,
  current_version : Int64,
  current_content : ContentIdentity,
  target_version : Int64,
  limits : @moonbsdiff.Limits,
  max_steps? : Int64,
  max_download_bytes? : Int64,
  allow_full? : Bool,
) -> Result[CatalogUpdatePlan, CatalogError]
```

```moonbit
pub struct CatalogRoutePlan {
  total_patch_bytes : Int64
  patch_indices : ReadOnlyArray[Int32]
  target : CatalogRelease
}

pub(all) enum CatalogUpdatePlan {
  UpToDate(CatalogRelease)
  Patches(CatalogRoutePlan)
  FullFile(CatalogRelease)
}
```

### Planning and anti-downgrade rules

1. **Parameter validation**: Validates `limits` (`InvalidLimits`), `max_steps > 0` when provided (`InvalidMaxSteps`), and `max_download_bytes >= 0` when provided (`InvalidMaxDownloadBytes`; `0` is allowed so an already-up-to-date client succeeds with zero download budget).
2. **Anti-downgrade gate**: Rejects if `target_version < catalog.min_version` **or** `target_version < current_version` with `DowngradeRejected(current_version~, target_version~, min_version~)`.
3. **Version and current-file binding**: Both `current_version` and `target_version` must exist in `catalog.releases` (`UnknownVersion`), and `current_content` must match the declared `size` and `sha256` of `current_version` (`CurrentIdentityMismatch`).
4. **Already up to date**: If `current_version == target_version`, returns `Ok(UpToDate(target_release))`.
5. **Target size bounds**: Checks `target_release.content.size` against both `limits.max_output_bytes` and `limits.max_new_bytes` (`LimitExceeded`).
6. **Monotonic edge filtering**: Builds the routable graph from `catalog.patches`, discarding any edge where:
   - `patch.size > limits.max_patch_bytes`;
   - `to_version < catalog.min_version`, `to_version < current_version`, or **`to_version <= from_version`** (forbids cycles and prevents routing through any intermediate downgrade hop);
   - `from_release.content.size > limits.max_old_bytes`, or `to_release.content.size > limits.max_new_bytes` / `limits.max_output_bytes`.
7. **Deterministic shortest path**: Matches `manifest/plan.mbt` tie-breaking identically — minimizes total `patch_size_bytes`, then hop count, then earliest discovery order (scanning outgoing edges in `catalog.patches` array order). When `max_steps` is set, caps depth to `min(requested, simple_path_depth)` and tracks hop-indexed states when `requested < simple_path_depth`.
8. **Fallback and download budget**:
   - `allow_full` defaults to `false`: requires a reachable patch route (`NoRoute(effective_max_steps~)` otherwise) and checks `route.total_patch_bytes <= max_download_bytes` (`BudgetExceeded`).
   - With `allow_full=true`: chooses `Patches(route)` only if a route exists and `route.total_patch_bytes < target_release.content.size` (strict `<`; ties choose `FullFile`); otherwise selects `FullFile(target_release)`, checking the chosen download size against `max_download_bytes` (`BudgetExceeded`).

### `CatalogError` reference

| Variant | Meaning |
| --- | --- |
| `InvalidLimits(@moonbsdiff.BsdiffError)` | Supplied `Limits` failed `Limits::validate()` |
| `InvalidEncoding` | Catalog bytes contain a UTF-8 BOM or invalid UTF-8 |
| `InvalidJson(field~, detail~)` | Malformed JSON, excessive nesting depth (`> 8`), or duplicate object key |
| `InvalidSchema(field~, detail~)` | Missing/unknown field, wrong type/range, duplicate release version/label, invalid hash/channel/label/URI, or dangling/self-loop patch edge |
| `LimitExceeded(field~, value~, limit~)` | Exceeded `max_catalog_file_bytes`, `max_catalog_releases`, `max_catalog_patches`, `max_new_bytes`, or `max_output_bytes` |
| `Signature(SignatureError)` | Detached Ed25519 key lookup, format, or cryptographic verification error |
| `CatalogHashMismatch(expected~, actual~)` | `SHA-256(catalog_bytes)` does not match `sig.catalog_sha256()` |
| `CatalogRollback(catalog_version~, min_catalog_version~)` | Verified catalog's `catalog_version` is below the caller's anti-replay floor |
| `DowngradeRejected(current_version~, target_version~, min_version~)` | Requested `target_version` is below `catalog.min_version` or `current_version` |
| `UnknownVersion(version~)` | `current_version` or `target_version` is not present in `catalog.releases` |
| `CurrentIdentityMismatch(version~, difference~)` | Installed file size or SHA-256 does not match `current_version` in the catalog |
| `InvalidMaxSteps(Int64)` | `max_steps <= 0` |
| `InvalidMaxDownloadBytes(Int64)` | `max_download_bytes < 0` |
| `NoRoute(effective_max_steps~)` | No forward patch route reaches `target_version` (when `allow_full` is `false`) |
| `BudgetExceeded(minimum_bytes~, max_download_bytes~)` | Cheapest valid plan exceeds `max_download_bytes` |

## MoonBit usage example

```moonbit
fn plan_from_signed_catalog(
  pinned_keys : Array[@manifest.PublicKey],
  catalog_bytes : Bytes,
  sig_bytes : Bytes,
  last_seen_catalog_version : Int64,
  current_version : Int64,
  installed_bytes : Bytes,
  target_version : Int64,
) -> Result[@manifest.CatalogUpdatePlan, String] {
  let store = match @manifest.TrustStore::from_keys(pinned_keys) {
    Ok(s) => s
    Err(e) => return Err(@debug.to_string(e))
  }
  let sig = match @manifest.CatalogSignature::from_json_bytes(sig_bytes) {
    Ok(s) => s
    Err(e) => return Err(@debug.to_string(e))
  }
  let verified = match
    store.verify_catalog(
      catalog_bytes,
      sig,
      min_catalog_version=last_seen_catalog_version,
    ) {
    Ok(v) => v
    Err(e) => return Err(@debug.to_string(e))
  }
  let current_id = @manifest.ContentIdentity::of_bytes(installed_bytes)
  match
    verified.plan_update(
      current_version,
      current_id,
      target_version,
      @moonbsdiff.Limits::for_apply(),
      max_steps=4L,
      allow_full=true,
    ) {
    Ok(plan) => Ok(plan)
    Err(e) => Err(@debug.to_string(e))
  }
}
```

## CLI commands (`moonbsdiff manifest catalog`)

The native CLI supports repeatable `--public-key` for key rotation across `manifest verify-sig`, `verify`, `patch`, `install-full`, `verify-chain`, `patch-chain`, `dir-verify`, `dir-patch`, and the three `manifest catalog` subcommands:

```sh
moonbsdiff manifest catalog sign --private-key release.priv.json catalog.json catalog.sig.json
moonbsdiff manifest catalog verify --public-key key-v1.pub.json --public-key key-v2.pub.json --signature catalog.sig.json --min-catalog-version 42 catalog.json
moonbsdiff manifest catalog plan --public-key key-v1.pub.json --public-key key-v2.pub.json --signature catalog.sig.json --current-version 1 --target-version 3 --min-catalog-version 42 --allow-full --json catalog.json installed.bin
```

`manifest catalog plan` verifies the detached catalog signature and `min_catalog_version` *before* opening `CURRENT_FILE`, hashes `CURRENT_FILE` by bounded 4096-byte streaming, and emits either text or Schema 1 JSON (`decision`: `"up-to-date"`, `"patches"`, or `"full-file"`).

Related docs: [manifest.md](manifest.md), [dir-delta.md](dir-delta.md), [analyze.md](analyze.md).
