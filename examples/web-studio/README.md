# MoonBSDiff Web Studio — Forensic & Verifiable Update Workbench

A zero-backend, 100% client-side engineering workbench powered by the real compiled MoonBit JavaScript ES module (`cmd/studio` calling `@moonbsdiff` and `@manifest` directly — zero mocked cryptography or simulated diffs).

## What Makes This Workbench Distinct

Rather than a single-file diff/patch form, MoonBSDiff Studio showcases four capabilities unique to MoonBSDiff's verifiable binary update architecture:

1. **Update Graph & Red-Team Lab** (`TrustStore` + `ReleaseCatalog` + `VerifiedCatalog::plan_update`)
   - Interactive SVG DAG (`v1.0.0 -> v1.1.0 -> v1.2.0 -> v2.0.0`) with live Dijkstra hop/budget controls.
   - Real Ed25519 signing, zero-downtime multi-key rotation, and four live red-team attacks: poisoned fake patch edge (`Signature(VerificationFailed)`), downgrade to revoked v1.0 (`DowngradeRejected`), old catalog replay (`CatalogRollback`), and tampered hop payload (`IdentityMismatch`).
2. **BSDIFF40 X-Ray & Bomb Auditor** (`@moonbsdiff.analyze_patch`)
   - Drag-and-drop any real `.patch` file or explore 6 built-in fixtures including a real `>700x` bzip2 decompression bomb, fast-path prefix/suffix edits, incompressible random payloads, negative-seek reordered blocks, and truncated patches.
   - Displays proportional wire-format segments (`32 B Header + CTRL + DIFF + EXTRA`), control tuples, preflight risk flags, and copyable minimum `Limits` structs + CLI flags.
3. **4 KiB Stream Oscilloscope** (`@moonbsdiff.apply_stream`)
   - Interactive waveform scrubber over real `<= 4096 B` output chunks, stage pipeline (`HeaderVerified -> Restoring -> Validating`), full callback event trace (`read_old_at`, `read_patch_at`, `write_output`, `checkpoint`), and an **Abort After Chunk N** slider proving fail-closed cancellation.
4. **Directory Delta Explorer** (`@manifest.dir_diff` + `dir_apply_signed`)
   - Built-in "Mini App v1 -> v2" bundle plus real local folder comparison (`<input webkitdirectory>`) showing `UNCHANGED (0 B)`, `RENAMED (0 B)`, `PATCHED`, `FULL_FALLBACK`, `ADDED`, and `DELETED`, verified `tree_sha256`, and live tamper attacks (`IdentityMismatch`, `Signature(VerificationFailed)`, `InvalidPath`).

## Build & Run Locally

From the repository root:

```sh
python scripts/build_web_studio.py
python -m http.server -d examples/web-studio 8080
```

Then open <http://127.0.0.1:8080> in any modern browser. Everything executes locally in the browser with zero network or backend dependencies.

## Automated Verification

```sh
python scripts/test_web_studio.py -v
```
