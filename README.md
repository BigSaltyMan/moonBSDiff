# MoonBSDiff

> **English** | [简体中文](https://github.com/BigSaltyMan/moonBSDiff/blob/master/README.zh-CN.md)

MoonBSDiff is a MoonBit library and native CLI for verifiable binary delta updates.
It generates and applies **BSDIFF40** patches compatible with BSDiff 4.3 using a linear-time **SA-IS** suffix-array engine, with preflight patch forensics, bounded streaming application, multi-key **Ed25519** signed release catalogs, and whole-directory delta bundles.

## Highlights

- **Standard BSDIFF40 & linear-time `O(n)` SA-IS** — Interoperates in both directions with BSDiff 4.3 across Native, JavaScript, and Wasm-GC; combines linear-time SA-IS suffix sorting with fast-path prefix/suffix trimming (`>= 64` bytes) and cross-target `apply_stream` (`<= 4096`-byte chunks).
- **Preflight patch forensics & bomb auditor** — Inspect ratios, control samples, deterministic risk flags (`HIGH_EXPANSION_RATIO`, `EXCESSIVE_CONTROL_DENSITY`, etc.), and tightest valid `required_limits` without needing old bytes or allocating output (`analyze_patch` / `inspect --analyze`).
- **Multi-key rotation & signed release catalogs** — Pin multiple Ed25519 public keys (`TrustStore` / repeatable `--public-key`), enforce anti-replay (`min_catalog_version`) and anti-downgrade routing (`VerifiedCatalog::plan_update` / `manifest catalog`), and authenticate multi-hop `patch-chain` / `verify-chain` updates.
- **Whole-directory delta bundles** — Diff, verify, and restore entire directory trees (`dir_diff` / `dir_apply_signed` / `dir-diff`, `dir-verify`, `dir-patch`) with canonical `tree_sha256`, 0-byte unchanged/rename deduplication, automatic BSDIFF40 vs. full-file fallback, strict path/symlink guards, and detached Ed25519 signatures.
- **Differentiated Web Studio & cross-platform CLI** — Zero-backend browser workbench ([Web Studio](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md)) powered by the real compiled MoonBit JS core, plus native CLI builds for Windows (`x86_64`), Linux (`x86_64`, `arm64`), and macOS (`arm64`).

## Entry Points

| Use case | Entry point |
| --- | --- |
| Generate, analyze, or stream-apply patches in MoonBit | [`BigSaltyMan/moonbsdiff`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/pkg.generated.mbti) (`native`, `js`, `wasm-gc`) |
| Verify manifests, rotate keys, plan signed catalogs, or diff directory trees | [`BigSaltyMan/moonbsdiff/manifest`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/manifest/pkg.generated.mbti) (`native`, `js`, `wasm-gc`) |
| Work with local files, catalogs, signed chains, and directory bundles | `moonbsdiff` CLI — Windows (`x86_64`), Linux (`x86_64`, `arm64`), macOS (`arm64`) |
| Interactive browser forensics, red-team catalog lab, stream trace & dir-delta UI | [MoonBSDiff Web Studio](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md) (`cmd/studio` -> JS ESM) |

---

## CLI Quick Start

Download the prebuilt archive for your platform from [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases), verify its SHA-256 checksum, and extract it.
Starting with `0.6.0`, release packaging covers Windows (`x86_64`), Linux (`x86_64`, `arm64`), and macOS (`arm64`); earlier `0.5.x` releases cover Windows and Linux (`x86_64`).
See the [CLI installation guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md) for checksum commands and runtime requirements.

### Basic single-file workflow & preflight forensics

```sh
# 1. Create a BSDIFF40 patch and a SHA-256 manifest from two files.
moonbsdiff diff --manifest update.json old.bin new.bin update.patch

# 2. Run preflight forensics, risk flags, and exact required_limits (or --deep).
moonbsdiff inspect --analyze --json update.patch

# 3. Verify the patch in streaming mode, then apply it to a new output path.
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin
```

### Ed25519 signing, key rotation & signed release catalogs

```sh
# Generate publisher keypairs (private keys use owner-only permissions).
moonbsdiff manifest keygen key-v1.key key-v1.pub
moonbsdiff manifest keygen key-v2.key key-v2.pub

# Sign a manifest or release catalog, then verify under overlapping trusted keys.
moonbsdiff manifest sign --private-key key-v1.key update.json update.sig
moonbsdiff patch --stream --manifest update.json \
  --public-key key-v1.pub --public-key key-v2.pub --signature update.sig \
  old.bin update.patch verified.bin

moonbsdiff manifest catalog sign --private-key key-v2.key catalog.json catalog.sig
moonbsdiff manifest catalog plan \
  --public-key key-v1.pub --public-key key-v2.pub --signature catalog.sig \
  --current-version 1 --target-version 3 --min-catalog-version 2 --allow-full --json \
  catalog.json old.bin
```

### Signed whole-directory delta bundles

```sh
# Diff old_dir -> new_dir into a signed bundle (0-byte unchanged/renames + BSDIFF40/fallback).
moonbsdiff dir-diff --private-key key-v2.key old_dir new_dir release_bundle

# Authenticate signature before reading inputs, verify tree hashes, and restore to a new directory.
moonbsdiff dir-verify --public-key key-v1.pub --public-key key-v2.pub \
  --signature release_bundle/dir-manifest.sig old_dir release_bundle
moonbsdiff dir-patch --public-key key-v1.pub --public-key key-v2.pub \
  --signature release_bundle/dir-manifest.sig old_dir release_bundle restored_dir
```

> **Notes**
> - Argument order for `patch` is `OLD PATCH OUTPUT`, and `OUTPUT` / `BUNDLE_DIR` / `OUTPUT_DIR` must not already exist.
> - Use `moonbsdiff <command> --help` (for example `moonbsdiff manifest catalog plan --help` or `moonbsdiff dir-diff -h`) to inspect flags and argument order.
> - See the [CLI reference](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md), [patch analysis guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md), [catalog & rotation guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/catalog.md), [directory delta guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md), and [streaming file behavior](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md).

---

## MoonBit Library

Add the module to your MoonBit project (append `@VERSION` to pin a specific release):

```sh
moon add BigSaltyMan/moonbsdiff
```

Import it in your `moon.pkg`:

```moonbit
import {
  "BigSaltyMan/moonbsdiff",
}
```

### Minimal in-memory example

```moonbit
fn main {
  let old = b"MoonBSDiff\x00version 1\xff"
  let expected = b"MoonBSDiff\x00version 2!\xff"
  let patch = @moonbsdiff.diff(old, expected, @moonbsdiff.Limits::for_diff()).unwrap()
  let restored = @moonbsdiff.apply(old, patch, @moonbsdiff.Limits::for_apply()).unwrap()
  if restored != expected {
    abort("restored bytes differ from the expected version")
  }
}
```

### Key APIs and behavior

- **Structured errors & linear-time SA-IS** — `diff` and `apply` return `Result[Bytes, BsdiffError]` with explicit failure kinds, stages, and resource bounds (`Limits::for_diff()`, `Limits::for_apply()`). Suffix-array construction uses linear-time `O(n)` SA-IS with bounded `SortBudget` accounting ([suffix-array guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/suffix-array.md)).
- **Fast-path `diff` vs. `DiffIndex::diff`** — Standalone `diff` automatically trims shared leading/trailing runs (`>= 64` bytes), skipping suffix-array sorting on identical, pure-insert, and pure-delete updates and sorting only the differing middle (trading away matches that copy prefix/suffix blocks into a differing middle). `DiffIndex::diff` preserves full-SA matching for all inserts and edits and uses the zero-search fast path only on identical or pure-delete pairs. Both emit standard BSDIFF40 patches.
- **Preflight forensics (`analyze_patch`) & streaming (`apply_stream`)** — Audit untrusted patches for decompression bombs, stream ratios, risk flags, and exact `required_limits` via `analyze_patch` ([patch analysis guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md)), or stream-apply in `<= 4096`-byte chunks via `apply_stream` ([application guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md)).
- **Manifests, multi-key catalogs & directory deltas** — Import `BigSaltyMan/moonbsdiff/manifest` for detached Ed25519 manifest signing ([manifest guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md)), multi-key `TrustStore` rotation, `verify_signed_candidates`, anti-replay/anti-downgrade `ReleaseCatalog` routing ([catalog guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/catalog.md)), and `dir_diff` / `dir_apply_signed` whole-directory delta bundles ([directory delta guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md)).

---

## Quick Acceptance Demos

### Comprehensive 0.7.0 acceptance runner

Verify all four 0.7.0 pillars end-to-end (patch forensics + bomb preflight, signed release catalog + key rotation + anti-downgrade/anti-replay, signed directory delta bundle + tamper/no-overwrite checks, and Web Studio Node ESM checks) with [`scripts/run_070_acceptance.py`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/scripts/run_070_acceptance.py):

```sh
# Full run (CLI + Web Studio Node ESM suite; add --skip-web to run CLI pillars only)
python scripts/run_070_acceptance.py --cli _build/bin/windows/moonbsdiff.exe
python3 scripts/run_070_acceptance.py --cli _build/bin/linux/moonbsdiff
python3 scripts/run_070_acceptance.py --cli _build/bin/macos/moonbsdiff
```

### Multi-hop update planning demo

An offline update demo script compares three update strategies on the same sample files, then executes the offline patch chain and byte-compares `restored.bin` against the independent target:

| Policy | Chosen route | Download size |
| --- | --- | --- |
| Max 1 hop | Full target file | **2048 bytes** |
| Max 2 hops | Two-step patch chain (`v1 -> v2 -> v3`) | **359 bytes** |
| Patches already local | Offline local patch chain | **0 bytes** |

Run it from the repository root with Python 3.10+ (CLI `unittest` suite requires Python 3.11+), pointing `--cli` to your platform binary:

```sh
# Windows (x86_64)
python scripts/run_update_demo.py --cli _build/bin/windows/moonbsdiff.exe

# Linux (x86_64 or arm64)
python scripts/run_update_demo.py --cli _build/bin/linux/moonbsdiff

# macOS (arm64)
python scripts/run_update_demo.py --cli _build/bin/macos/moonbsdiff
```

When using a downloaded release archive, replace `--cli` with the extracted binary path. After `UPDATE DEMO PASS`, inspect the printed directory for the verified output file.

> **Version note:** `0.6.0` and later produce a `155`-byte `v2-to-v3.patch` (`359` bytes total) with the prefix/suffix fast path. Earlier `v0.5.0`–`v0.5.4` binaries produce `164` bytes (`368` bytes total) and should be checked with `scripts/run_update_demo.py` from their matching git tag.
> See [demo steps, expected SHA-256 digests, and sample provenance](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/update-demo.md).

---

## Build from Source & Test

### Prerequisites

- **MoonBit toolchain**: `moon 0.1.20261126`, `moonc v1.0.0-rc1+3c0520448`
- **Python**: `3.10+` for build, packaging, and demo scripts (`3.11+` for the CLI `unittest` suite, which uses `contextlib.chdir`)
- **Node.js**: required for `--target js` tests and [Web Studio](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md) verification
- **C compiler**: Native C toolchain (on Windows, run from an initialized MSVC developer shell)

### Build & verify

```sh
moon update
python scripts/build_cli.py --release
moon run cmd/example --target js
moon test --target native --deny-warn
python scripts/test_web_studio.py -v
```

The build script writes the native CLI to `_build/bin/windows/moonbsdiff.exe`, `_build/bin/linux/moonbsdiff`, or `_build/bin/macos/moonbsdiff`.

Release packaging covers **4 CI-built native targets** (`windows-x86_64`, `linux-x86_64`, `linux-arm64`, `macos-arm64`), emitting **6 release assets** (`4 archives + SHA256SUMS + build-info.json`). Intel macOS (`macos-x86_64`) is not built in CI because upstream MoonBit `1.0.0-rc1` does not publish `darwin-x86_64` native toolchains.

See [compatibility & BSDiff interoperability](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) and [CI workflow results](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml).

---

## Limits & Security Model

- **Bounded resources & bomb preflight** — Default generation accepts old/new buffers up to **64 KiB** and caps patches at **128 KiB**; default application and `analyze_patch` enforce patch, output, cumulative decompression, and control caps fail-closed. See [generation scales (256 KiB and 1 MiB policies)](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md) and [patch analysis](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md).
- **Content integrity vs. publisher trust** — BSDIFF40 carries no built-in file hash, and unsigned manifests verify SHA-256 content identity only. Publisher authentication requires pinning trusted Ed25519 keys out-of-band (`TrustStore` / `--public-key`) and verifying domain-separated detached signatures (`moonbsdiff-manifest-ed25519-v1\x00`, `moonbsdiff-catalog-ed25519-v1\x00`, `moonbsdiff-dir-manifest-ed25519-v1\x00`) with monotonic `min_catalog_version` anti-replay and anti-downgrade routing.
- **Non-destructive delivery & path safety** — The CLI never overwrites existing files or directories, refuses symlinks and Windows reparse points during directory delta operations, rejects unsafe or case-colliding relative paths, and delivers through private temporary objects. See [delivery and cancellation behavior](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md) and [directory delta bundles](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md).

---

## Documentation & References

| Topic | Links |
| --- | --- |
| **Usage guides** | [CLI installation](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md) · [CLI reference](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md) · [Application guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md) · [Patch analysis](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md) · [Manifest & signing](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md) · [Catalogs & rotation](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/catalog.md) · [Directory deltas](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md) · [File delivery](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md) |
| **Interactive & demos** | [Web Studio](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md) · [0.7.0 acceptance runner](https://github.com/BigSaltyMan/moonBSDiff/blob/master/scripts/run_070_acceptance.py) · [Update demo guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/update-demo.md) |
| **Technical details** | [BSDIFF40 format](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/format.md) · [SA-IS suffix array](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/suffix-array.md) · [Generation scales](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md) · [Benchmarks](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/benchmarks.md) · [Compatibility](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) |
| **Project & releases** | [Changelog](https://github.com/BigSaltyMan/moonBSDiff/blob/master/CHANGELOG.md) · [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases) · [BSD-2-Clause License](https://github.com/BigSaltyMan/moonBSDiff/blob/master/LICENSE) · [Upstream & third-party notices](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/upstream.md) |
