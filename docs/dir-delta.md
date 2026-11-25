# Directory delta bundles (`dir_diff` and `dir_apply`)

MoonBSDiff **0.7.0** introduces deterministic whole-directory delta bundles in `BigSaltyMan/moonbsdiff/manifest`:

- Schema 1 `DirManifest` with canonical `tree_sha256` digests for both source and target trees;
- strict POSIX relative-path (`validate_relative_path`) and blob-name security rules;
- zero-byte unchanged and rename/copy deduplication;
- automatic per-file BSDIFF40 patching with transparent full-file fallback;
- detached domain-separated Ed25519 signing (`DIR_MANIFEST_SIGNATURE_DOMAIN`) and fail-closed `dir_apply_signed`.

The core library operates purely on in-memory `DirFileEntry` and `DirBlob` collections across **native, JS, and Wasm-GC**. The native CLI adds no-symlink, no-overwrite filesystem commands (`dir-diff`, `dir-verify`, `dir-patch`).

## Public MoonBit API (`BigSaltyMan/moonbsdiff/manifest`)

### Constants

| Constant | Type | Value |
| --- | --- | --- |
| `DIR_MANIFEST_SIGNATURE_DOMAIN` | `Bytes` | `b"moonbsdiff-dir-manifest-ed25519-v1\x00"` |
| `max_dir_manifest_bytes` | `Int32` | `524288` (512 KiB) |
| `max_signature_file_bytes` | `Int32` | `4096` (4 KiB, shared across signature envelopes) |

### Core functions

```moonbit
pub fn validate_relative_path(String) -> Result[Unit, DirDeltaError]
pub fn tree_sha256(Array[DirFileEntry]) -> Result[String, DirDeltaError]
pub fn dir_diff(Array[DirFileEntry], Array[DirFileEntry], @moonbsdiff.Limits) -> Result[DirDeltaBundle, DirDeltaError]
pub fn dir_summarize(DirManifest) -> DirDeltaSummary
pub fn dir_apply(Array[DirFileEntry], Bytes, Array[DirBlob], @moonbsdiff.Limits) -> Result[(Array[DirFileEntry], DirDeltaSummary), DirDeltaError]
pub fn dir_apply_signed(Array[DirFileEntry], Bytes, DirManifestSignature, Array[PublicKey], Array[DirBlob], @moonbsdiff.Limits) -> Result[(Array[DirFileEntry], DirDeltaSummary, PublicKey), DirDeltaError]
pub fn verify_dir_manifest_signature(Bytes, DirManifestSignature, PublicKey) -> Result[Unit, SignatureError]
pub fn verify_dir_manifest_signature_with_keys(Bytes, DirManifestSignature, Array[PublicKey]) -> Result[PublicKey, SignatureError]
```

### Core types

- `DirFileEntry` (`pub(all) struct`): `{ path : String, bytes : Bytes }`
- `DirBlob` (`pub(all) struct`): `{ name : String, bytes : Bytes }`
- `DirDeltaBundle` (read-only struct): `{ manifest : DirManifest, manifest_bytes : Bytes, blobs : ReadOnlyArray[DirBlob] }`
- `DirManifest` (read-only struct with `from_json_bytes`, `to_json_bytes`):
  `old_tree_sha256`, `new_tree_sha256`, `old_file_count : Int32`, `new_file_count : Int32`, `old_total_bytes : Int64`, `new_total_bytes : Int64`, `delta_payload_bytes : Int64`, `entries : ReadOnlyArray[DirEntryAction]`
- `DirEntryAction` (`pub(all) enum`):
  - `Unchanged(path~ : String, identity~ : ContentIdentity)`
  - `Renamed(path~ : String, from_path~ : String, identity~ : ContentIdentity)`
  - `Patched(path~ : String, from_path~ : String, old_identity~ : ContentIdentity, new_identity~ : ContentIdentity, patch_identity~ : ContentIdentity, blob_name~ : String)`
  - `Added(path~ : String, identity~ : ContentIdentity, blob_name~ : String, full_fallback~ : Bool)`
  - `Deleted(path~ : String, old_identity~ : ContentIdentity)`
- `DirDeltaSummary` (read-only struct): `unchanged_count`, `renamed_count`, `patched_count`, `added_count` (all `Added` entries, including fallbacks), `full_fallback_count` (subset of `Added` with `full_fallback == true`), `deleted_count`, `old_total_bytes`, `new_total_bytes`, `delta_payload_bytes`, `old_tree_sha256`, `new_tree_sha256`.
- `DirManifestSignature` (opaque struct): `from_json_bytes`, `to_json_bytes`, `key_id`, `dir_manifest_sha256`, `signature_bytes`, `signature_hex`; created via `PrivateKey::sign_dir_manifest(Bytes) -> Result[DirManifestSignature, DirDeltaError]`.

## Path security (`validate_relative_path`) and `tree_sha256`

### `validate_relative_path` rules

Every relative path entering `tree_sha256`, `dir_diff`, `dir_apply`, or `DirManifest::from_json_bytes` must pass `validate_relative_path`:

- **Non-empty and bounded**: `1..1024` UTF-16 code units **and** `1..1024` UTF-8 bytes (`InvalidPath` if empty or `> 1024`).
- **Well-formed Unicode**: Unpaired UTF-16 surrogates (`0xD800..0xDFFF`) are rejected so UTF-8 encoding is lossless and canonical.
- **Strict POSIX relative form**:
  - Must not start with `/` (absolute path) or end with `/`.
  - Must not contain backslashes (`\`).
  - Must not contain NUL (`0x00`), ASCII control bytes (`0x00..0x1F`, `0x7F`), or Unicode C1 control characters (`U+0080..U+009F`).
- **Segment hygiene**: Splitting on `/` must yield no empty segment (`a//b`), no `.` segment (`.`, `./x`, `a/./b`), and no `..` segment (`..`, `../escape`, `a/../b`). Double dots inside a filename (`a..b/c`) and dotfiles (`assets/.env`) remain valid.
- **No Windows drive prefix**: The **first** segment must not contain `:` (rejects `C:foo`, `C:foo/bar`; colons in nested segments like `dir/sub:name` are permitted).

### Tree-set and blob-name safety

In addition to per-path validation:

- **Duplicate paths** in a tree are rejected with `DuplicatePath(path)`.
- **File-vs-directory prefix collisions** (such as `"foo"` and `"foo/bar/baz"`, even when separated by other paths like `"foo-extra"` or `"foo.txt"` in sort order) are rejected with `PathCollision(a~, b~)`.
- **Blob names** (`blob_name` in manifests and `DirBlob.name` in `dir_apply`) must be `1..255` UTF-8 bytes matching `[A-Za-z0-9._-]+`, must not start with `.`, and must not contain `..` (`InvalidBlobName`). `dir_diff` emits deterministic zero-padded names `blob-0001.patch`, `blob-0002.full`, etc.

### Canonical `tree_sha256`

`tree_sha256(entries)` computes a deterministic, input-order-independent SHA-256 digest over a validated directory tree:

1. Validates every path and checks uniqueness and prefix-collision freedom.
2. Sorts entries by **unsigned UTF-8 byte order** of `path` (ensuring identical ordering across UTF-16 and UTF-8 runtimes, including supplementary code points like `U+10000` vs BMP `> 0xDFFF`).
3. If the tree is empty (`[]`), returns `SHA-256(b"")` (`e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).
4. Otherwise formats one UTF-8 line per sorted file and hashes their concatenation:

```text
<sha256_hex> <size_bytes> <path>\n
```

## Deduplication and automatic BSDIFF40 vs full-file fallback (`dir_diff`)

`dir_diff(old_entries, new_entries, limits)` validates `limits` and both trees, then walks every entry in `new_entries` in canonical UTF-8 path order (enforcing per-file `limits.max_old_bytes`, `limits.max_new_bytes`, and `limits.max_output_bytes` on `Unchanged` and `Renamed` entries as well, and tracking cumulative cross-action `cloned_bytes <= limits.max_output_bytes` across reused old paths so excess `Renamed` / `Patched` clones fall back to `Added` for `dir_diff` -> `dir_apply` parity):

1. **Unchanged (`0` payload bytes)**: If `path` exists in `old` with the exact same `ContentIdentity` (`size` and `sha256`), emits `Unchanged(path~, identity~)`.
2. **Renamed / deduplicated (`0` payload bytes)**: Else if any file in `old` has the exact same `(size, sha256)`:
   - Chooses the first matching old path (in UTF-8 order) that is **no longer present** in `new` (a move/rename);
   - If all matching old paths still exist in `new`, chooses the first matching old path (content-deduplicating a file copy).
   - Emits `Renamed(path~, from_path~, identity~)` without storing any blob.
3. **Modified file at same path — automatic BSDIFF40 vs full-file fallback**:
   - First enforces **both** `new_file.identity.size <= limits.max_new_bytes` and `new_file.identity.size <= limits.max_output_bytes` (`LimitExceeded`) before attempting a diff or emitting a full blob, ensuring `dir_diff` never emits a brand-new or `full_fallback=true` blob that `dir_apply` would reject under the same `Limits`.
   - Runs `@moonbsdiff.diff(old_same.bytes, new_file.bytes, limits)`:
     - If `diff` succeeds **and** `patch.length() < new_file.bytes.length()` (strictly smaller than the full new file), stores `blob-XXXX.patch` and emits `Patched(...)`.
     - Otherwise (the BSDIFF40 patch is `>=` the new file size, or `diff` returns an error such as an input/work/patch cap on an incompressible file), automatically falls back to storing the complete new file as `blob-XXXX.full` and emits `Added(..., full_fallback=true)`.
4. **Brand-new file**: After enforcing `limits.max_new_bytes` and `limits.max_output_bytes`, if `path` is absent from `old` and has no identical-content source in `old`, stores `blob-XXXX.full` and emits `Added(..., full_fallback=false)`.
5. **Deleted files**: Finally walks `old` in UTF-8 path order and emits `Deleted(path~, old_identity~)` for every old path absent from `new`.

Finally, `dir_diff` serializes the manifest with `DirManifest::to_json_bytes()` and verifies its serialized size fits `max_dir_manifest_bytes` (`524288` bytes).

## Schema 1 `DirManifest`

Canonical JSON bytes emitted by `DirManifest::to_json_bytes` end with a single `\n` (pretty-printed below for readability):

```json
{
  "schema": 1,
  "type": "moonbsdiff-dir-manifest",
  "old_tree_sha256": "<64 lowercase hex>",
  "new_tree_sha256": "<64 lowercase hex>",
  "old_file_count": 5,
  "new_file_count": 4,
  "old_total_bytes": "7191",
  "new_total_bytes": "7175",
  "delta_payload_bytes": "214",
  "entries": [
    {
      "action": "added",
      "path": "VERSION",
      "identity": { "size_bytes": "7", "sha256": "<64 hex>" },
      "blob_name": "blob-0001.full",
      "full_fallback": true
    },
    {
      "action": "unchanged",
      "path": "assets/logo.bin",
      "identity": { "size_bytes": "1024", "sha256": "<64 hex>" }
    },
    {
      "action": "patched",
      "path": "bin/app.bin",
      "from_path": "bin/app.bin",
      "old_identity": { "size_bytes": "4096", "sha256": "<64 hex>" },
      "new_identity": { "size_bytes": "4096", "sha256": "<64 hex>" },
      "patch_identity": { "size_bytes": "207", "sha256": "<64 hex>" },
      "blob_name": "blob-0002.patch"
    },
    {
      "action": "renamed",
      "path": "docs/guide-v2.txt",
      "from_path": "docs/guide.txt",
      "identity": { "size_bytes": "2048", "sha256": "<64 hex>" }
    },
    {
      "action": "deleted",
      "path": "legacy/old.cfg",
      "old_identity": { "size_bytes": "16", "sha256": "<64 hex>" }
    }
  ]
}
```

Strict validation rules in `DirManifest::from_json_bytes`:

- Enforces `<= 524288` bytes, no UTF-8 BOM, valid UTF-8, `max_nesting_depth = 16`, `reject_duplicate_keys = true`, and exact allowed fields on the root object and every entry/identity object.
- `old_file_count` and `new_file_count` are nonnegative `Int32` JSON integers; all 64-bit byte totals (`old_total_bytes`, `new_total_bytes`, `delta_payload_bytes`, and every `size_bytes`) are lossless nonnegative ASCII decimal **strings** without leading zeros, overflow-checked against `Int64::max`.
- Rejects `renamed` entries where `path == from_path`, duplicate blob references (`DuplicateBlob`), duplicate `patched` `from_path` references (`InvalidSchema(field="entries", ...)`, blocking `Patched` fan-out upfront in `from_json_bytes`, `sign_dir_manifest`, and `dir_apply` before blob hashing or bzip2 decompression), duplicate or prefix-colliding paths in either new or asserted old trees, paths simultaneously present in `new` and `deleted`, and conflicting `old_identity` assertions for the same old path.
- Cross-checks declared `new_file_count`, `new_total_bytes`, `delta_payload_bytes`, `old_file_count` consistency (including `old_file_count <= new_file_count + deleted_paths.length()`, `sum(old_asserted_sizes) <= old_total_bytes`, equality when all `old_file_count` paths are asserted, and empty-tree digest with `old_total_bytes == 0` when `old_file_count == 0`), and recomputes `new_tree_sha256` from the entries.

## Detached signing and fail-closed `dir_apply_signed`

### Domain separation and signature envelope

`PrivateKey::sign_dir_manifest(manifest_bytes)` validates `manifest_bytes` against Schema 1 first, then computes a strict RFC 8032 Ed25519 signature over:

```text
DIR_MANIFEST_SIGNATURE_DOMAIN || manifest_bytes
  where DIR_MANIFEST_SIGNATURE_DOMAIN = b"moonbsdiff-dir-manifest-ed25519-v1\x00"
```

This domain is distinct from both single-file manifests (`moonbsdiff-manifest-ed25519-v1\x00`) and release catalogs (`moonbsdiff-catalog-ed25519-v1\x00`), preventing cross-type signature replay.

`DirManifestSignature::to_json_bytes` emits a Schema 1 JSON envelope (capped at `max_signature_file_bytes = 4096`, `max_nesting_depth = 4`, no BOM/duplicate/unknown keys):

```json
{
  "schema": 1,
  "type": "moonbsdiff-dir-manifest-signature",
  "algorithm": "ed25519",
  "key_id": "0123456789abcdef",
  "dir_manifest_sha256": "<64 lowercase hex>",
  "signature": "<128 lowercase hex>"
}
```

`verify_dir_manifest_signature_with_keys(manifest_bytes, sig, keys)` supports key rotation over a non-empty pinned key list: it rejects an empty list with `InvalidPublicKey`, validates and deduplicates every key via `TrustStore::from_keys` (rejecting non-canonical/small-order keys and conflicting distinct keys sharing a `key_id`, while deduplicating repeated keys in first-seen order so `KeyIdMismatch.expected` contains unique `key_id`s), and verifies against the matching `PublicKey` (failing closed with `LimitExceeded`, `InvalidPublicKey`, `KeyIdMismatch`, `ManifestHashMismatch`, `InvalidSignatureFormat`, or `VerificationFailed`).

### Fail-closed application order (`dir_apply_signed` and `dir_apply`)

1. **Signature verification first (`dir_apply_signed` only)**: Calls `verify_dir_manifest_signature_with_keys(manifest_bytes, sig, keys)` **before** parsing `manifest_bytes`, hashing `old_entries`, or inspecting `blobs`. Any signature error returns `Err(Signature(...))` immediately.
2. **Preflight and `old_tree_sha256` gate**: Validates `limits`, validates and sorts `old_entries`, parses and validates `DirManifest`, and verifies `old_tree_sha256` (`OldTreeMismatch`), `old_file_count`, and `old_total_bytes`.
3. **Complete blob inventory check**: Validates every `DirBlob.name` (`InvalidBlobName`), rejects duplicate blobs (`DuplicateBlob`), verifies every referenced blob is supplied (`MissingBlob`), and rejects any unreferenced extra blob (`UnexpectedBlob`).
4. **Per-entry limit, clone-budget, and identity enforcement**:
   - `Unchanged`: enforces `max_old_bytes`, `max_new_bytes`, and `max_output_bytes` (`LimitExceeded`); verifies `old_file` exists (`MissingOldFile`) and matches its declared `Old` identity (`IdentityMismatch`).
   - `Renamed`: enforces `max_old_bytes`, `max_new_bytes`, and `max_output_bytes`, tracks reused old paths (`used_old_paths`), and caps cumulative cross-action `cloned_bytes <= limits.max_output_bytes` (`LimitExceeded(field="max_output_bytes", ...)`) before verifying `Old` identity.
   - `Patched`: enforces `max_old_bytes`, `max_patch_bytes`, `max_new_bytes`, and `max_output_bytes` plus the shared cross-action `cloned_bytes <= limits.max_output_bytes` cap when reusing an old path already referenced by `Unchanged`/`Renamed` (each `Patched.from_path` itself is unique per manifest); checks `Old` and `Patch` identities; verifies `@moonbsdiff.inspect_header` reports `header.new_bytes == new_identity.size` (`PatchTarget`); applies via `@moonbsdiff.apply` (`ApplyError`); verifies restored bytes against `new_identity` (`Restored`).
   - `Added` (both `full_fallback == false` and `full_fallback == true`): enforces `max_new_bytes` and `max_output_bytes` (`LimitExceeded`) and verifies the full blob against `identity` (`Restored`).
   - `Deleted`: verifies the source old file exists (`MissingOldFile`) and matches its declared `Old` identity (`IdentityMismatch`).
5. **Explicit deletion completeness check**: Verifies that every path present in `old_entries` is accounted for in either the restored tree or an explicit `Deleted` entry, rejecting silent deletions with `InvalidSchema(field="entries", ...)`.
6. **Final `new_tree_sha256` check**: Re-sorts restored entries in canonical UTF-8 path order and verifies `new_tree_sha256`, `new_file_count`, and `new_total_bytes` (`NewTreeMismatch`) before returning `(restored_entries, summary)` (plus the verifying `PublicKey` from `dir_apply_signed`).

### `DirDeltaError` reference

| Variant | Meaning |
| --- | --- |
| `InvalidPath(path~, detail~)` | Path failed `validate_relative_path` |
| `DuplicatePath(String)` | Same path appears more than once in a tree or deleted list |
| `PathCollision(a~, b~)` | File path `a` collides with directory prefix of path `b` |
| `InvalidBlobName(name~, detail~)` | Blob name is empty, `> 255` bytes, starts with `.`, contains `..`, or uses characters outside `[A-Za-z0-9._-]` |
| `DuplicateBlob(String)` | Blob name supplied or referenced more than once |
| `MissingBlob(String)` | Manifest references a blob missing from `blobs` |
| `UnexpectedBlob(String)` | `blobs` contains an unreferenced extra blob |
| `InvalidLimits(@moonbsdiff.BsdiffError)` | Supplied `Limits` failed `Limits::validate()` |
| `LimitExceeded(field~, value~, limit~)` | Exceeded `max_dir_manifest_bytes`, `max_old_bytes`, `max_patch_bytes`, `max_new_bytes`, `max_output_bytes`, or `Int64` byte-total cap |
| `InvalidEncoding` | Manifest bytes contain a UTF-8 BOM or invalid UTF-8 |
| `InvalidJson(field~, detail~)` | Malformed JSON, nesting depth `> 16`, or duplicate key |
| `InvalidSchema(field~, detail~)` | Schema violation, type/range mismatch, or cross-check failure |
| `OldTreeMismatch(expected~, actual~)` | Source directory `tree_sha256` does not match `manifest.old_tree_sha256` |
| `NewTreeMismatch(expected~, actual~)` | Restored directory `tree_sha256`, file count, or byte total does not match manifest |
| `MissingOldFile(path~)` | Entry references an old file absent from `old_entries` |
| `IdentityMismatch(path~, object~, difference~)` | Size or SHA-256 mismatch on `Old`, `Patch`, `PatchTarget`, or `Restored` |
| `ApplyError(path~, error~)` | `@moonbsdiff.inspect_header` or `@moonbsdiff.apply` failed for `path` |
| `Signature(SignatureError)` | Detached Ed25519 signature parsing or verification failed |

## MoonBit usage example

```moonbit
fn roundtrip_signed_dir_delta(
  old_tree : Array[@manifest.DirFileEntry],
  new_tree : Array[@manifest.DirFileEntry],
  signing_key : @manifest.PrivateKey,
  trusted_keys : Array[@manifest.PublicKey],
) -> Result[Array[@manifest.DirFileEntry], String] {
  let bundle = match
    @manifest.dir_diff(old_tree, new_tree, @moonbsdiff.Limits::for_diff()) {
    Ok(b) => b
    Err(e) => return Err(@debug.to_string(e))
  }
  let sig = match signing_key.sign_dir_manifest(bundle.manifest_bytes) {
    Ok(s) => s
    Err(e) => return Err(@debug.to_string(e))
  }
  let blobs : Array[@manifest.DirBlob] = []
  for blob in bundle.blobs {
    blobs.push(blob)
  }
  match
    @manifest.dir_apply_signed(
      old_tree,
      bundle.manifest_bytes,
      sig,
      trusted_keys,
      blobs,
      @moonbsdiff.Limits::for_apply(),
    ) {
    Ok((restored, _summary, _verified_key)) => Ok(restored)
    Err(e) => Err(@debug.to_string(e))
  }
}
```

## CLI commands (`dir-diff`, `dir-verify`, `dir-patch`)

```sh
moonbsdiff dir-diff --private-key release.priv.json old_dir new_dir bundle_dir
moonbsdiff dir-verify --public-key key-v1.pub.json --public-key key-v2.pub.json --signature bundle_dir/dir-manifest.sig old_dir bundle_dir
moonbsdiff dir-patch --public-key key-v1.pub.json --public-key key-v2.pub.json --signature bundle_dir/dir-manifest.sig old_dir bundle_dir output_dir
```

- **On-disk bundle layout**: `dir-diff` creates a brand-new `BUNDLE_DIR` containing `dir-manifest.json`, optional `dir-manifest.sig` (when `--private-key` is supplied), and `blobs/blob-XXXX.{patch,full}` (omitted when the delta has zero payload blobs).
- **Filesystem safety**: All three commands reject symlinks and Windows reparse points when traversing `OLD_DIR`, `NEW_DIR`, and `BUNDLE_DIR`, validate every path with `validate_relative_path`, enforce full Unicode 16.0 case-folding collision checks on case-insensitive filesystems (Windows NTFS, WSL2 DrvFs, macOS case-insensitive APFS/HFS+, and Linux `NTFS3`), and refuse to overwrite existing or nested `BUNDLE_DIR` / `OUTPUT_DIR` targets. On Windows, the CLI additionally rejects `\\.\` / `//./` device-namespace paths, unconditional trailing `.` or space on segments/leaves, and extended DOS device names (`CON`, `PRN`, `AUX`, `NUL`, `COM0`–`COM9`, `LPT0`–`LPT9`, `CONIN$`, `CONOUT$`, `COM¹²³`, `LPT¹²³`), and resolves `dir-diff` directory reads via canonical `\\?\` extended paths so names such as `file` and `file.` read distinct contents without Win32 normalization aliasing.
- **Verify-before-read**: When `--public-key` and `--signature` are given, `dir-verify` and `dir-patch` verify the detached Ed25519 signature against `dir-manifest.json` *before* opening `OLD_DIR` or reading any file in `blobs/`.

Related docs: [manifest.md](manifest.md), [catalog.md](catalog.md), [analyze.md](analyze.md), [apply.md](apply.md).
