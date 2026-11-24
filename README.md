# MoonBSDiff

> **English** | [简体中文](https://github.com/BigSaltyMan/moonBSDiff/blob/master/README.zh-CN.md)

MoonBSDiff is a MoonBit library and native CLI for binary delta updates.
It generates and applies **BSDIFF40** patches compatible with BSDiff 4.3, with bounded resource limits, streaming application, SHA-256 update manifests, and optional detached **Ed25519** publisher signatures.

## Highlights

- **Standard BSDIFF40 compatibility** — Interoperates in both directions with BSDiff 4.3, across Native, JavaScript, and Wasm-GC targets.
- **Fast-path diff & streaming apply** — Trims long shared prefixes/suffixes (`>= 64` bytes) for fast standalone diffs, and provides cross-target `apply_stream` in bounded `<= 4096`-byte chunks.
- **Verified & signed updates** — Pair patches with Schema 1 SHA-256 manifests for route planning and content checks, and authenticate publishers with detached Ed25519 signatures.
- **Bounded & safe by default** — Enforces memory, decompression, and work limits in the library; the CLI never overwrites existing output files and delivers through private temporary objects.
- **Cross-platform native CLI** — Supports Windows (`x86_64`), Linux (`x86_64`, `arm64`), and macOS (`arm64`).

## Entry Points

| Use case | Entry point |
| --- | --- |
| Generate, inspect, or stream-apply patches in MoonBit | [`BigSaltyMan/moonbsdiff`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/pkg.generated.mbti) (`native`, `js`, `wasm-gc`) |
| Verify, sign, or plan updates in MoonBit | [`BigSaltyMan/moonbsdiff/manifest`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/manifest/pkg.generated.mbti) (`native`, `js`, `wasm-gc`) |
| Work with local files, signatures, and patch chains | `moonbsdiff` CLI — Windows (`x86_64`), Linux (`x86_64`, `arm64`), macOS (`arm64`) |

---

## CLI Quick Start

Download the prebuilt archive for your platform from [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases), verify its SHA-256 checksum, and extract it.
Starting with `0.6.0`, release packaging covers Windows (`x86_64`), Linux (`x86_64`, `arm64`), and macOS (`arm64`); earlier `0.5.x` releases cover Windows and Linux (`x86_64`).
See the [CLI installation guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md) for checksum commands and runtime requirements.

### Basic workflow

```sh
# 1. Create a BSDIFF40 patch and a SHA-256 manifest from two files.
moonbsdiff diff --manifest update.json old.bin new.bin update.patch

# 2. Inspect compressed streams and control instructions.
moonbsdiff inspect --deep update.patch

# 3. Verify the patch in streaming mode, then apply it to a new output path.
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin
```

### Optional: Ed25519 publisher signing

```sh
# Generate a publisher keypair (private key is written with owner-only permissions).
moonbsdiff manifest keygen publisher.key publisher.pub

# Sign the manifest into a detached signature file and verify it independently.
moonbsdiff manifest sign --private-key publisher.key update.json update.sig
moonbsdiff manifest verify-sig --public-key publisher.pub --signature update.sig update.json

# Require signature authentication before opening inputs or writing output.
moonbsdiff patch --stream \
  --manifest update.json \
  --public-key publisher.pub \
  --signature update.sig \
  old.bin update.patch verified.bin
```

> **Notes**
> - Argument order for `patch` is `OLD PATCH OUTPUT`, and `OUTPUT` must not already exist.
> - Use `moonbsdiff <command> --help` (for example `moonbsdiff manifest plan --help` or `moonbsdiff diff -h`) to inspect flags and argument order.
> - See the [CLI reference](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md), [manifest guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md), and [streaming file behavior](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md).

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

- **Structured errors & limits** — `diff` and `apply` return `Result[Bytes, BsdiffError]` with explicit failure kinds, stages, and resource bounds (`Limits::for_diff()`, `Limits::for_apply()`).
- **Fast-path `diff` vs. `DiffIndex::diff`** — Standalone `diff` automatically trims shared leading/trailing runs (`>= 64` bytes), skipping suffix-array sorting on identical, pure-insert, and pure-delete updates and sorting only the differing middle (trading away matches that copy prefix/suffix blocks into a differing middle). `DiffIndex::diff` preserves full-SA matching for all inserts and edits and uses the zero-search fast path only on identical or pure-delete pairs. Both emit standard BSDIFF40 patches.
- **Cross-target streaming (`apply_stream`)** — Apply patches with callback range readers (`read_old_at`, `read_patch_at`) and chunked `write_output` (`<= 4096`-byte chunks) on Native, JS, and Wasm-GC. See the [application guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md).
- **Manifests, planning & Ed25519 signatures** — Import `BigSaltyMan/moonbsdiff/manifest` to check SHA-256 content identities, choose between full-file downloads and patch chains (`plan_update`), or authenticate manifests with detached Ed25519 signatures (`prepare_signed`, `apply_signed`, `verify_manifest_signature`). See the [manifest guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md).

---

## Quick Acceptance Demo

An end-to-end demo script compares three update strategies on the same sample files, then executes the offline patch chain and byte-compares `restored.bin` against the independent target:

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

- **MoonBit toolchain**: `moon 0.1.20261102`, `moonc v0.10.19+bee578715`
- **Python**: `3.10+` for build, packaging, and demo scripts (`3.11+` for the CLI `unittest` suite, which uses `contextlib.chdir`)
- **C compiler**: Native C toolchain (on Windows, run from an initialized MSVC developer shell)

### Build & verify

```sh
moon update
python scripts/build_cli.py --release
moon run cmd/example --target js
moon test --target native --deny-warn
```

The build script writes the native CLI to `_build/bin/windows/moonbsdiff.exe`, `_build/bin/linux/moonbsdiff`, or `_build/bin/macos/moonbsdiff`.

Release packaging covers **4 CI-built native targets** (`windows-x86_64`, `linux-x86_64`, `linux-arm64`, `macos-arm64`), emitting **6 release assets** (`4 archives + SHA256SUMS + build-info.json`). Intel macOS (`macos-x86_64`) is not built in CI because upstream MoonBit `0.10.19` does not publish `darwin-x86_64` native toolchains.

See [compatibility & BSDiff interoperability](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) and [CI workflow results](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml).

---

## Limits & Security Model

- **Bounded resources** — Default generation accepts old/new buffers up to **64 KiB** and caps patches at **128 KiB**; default library application uses the same patch cap and also bounds output size, total decompression, and work budgets. See [generation scales (256 KiB and 1 MiB policies)](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md).
- **Content integrity vs. publisher trust** — BSDIFF40 carries no built-in file hash. Unsigned Schema 1 manifests verify content identity (SHA-256) only. Publisher authentication requires pinning the publisher's trusted Ed25519 `PUBLIC_KEY_FILE` (or `PublicKey`) out-of-band and verifying a detached signature (`--public-key` + `--signature`, `manifest verify-sig`, or `prepare_signed`/`apply_signed`).
- **Non-destructive delivery** — The CLI never overwrites existing files. Streaming verification and output delivery use private temporary objects; POSIX delivery on Linux and macOS depends on the target filesystem and protected parent directory permissions. See [delivery and cancellation behavior](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md).

---

## Documentation & References

| Topic | Links |
| --- | --- |
| **Usage guides** | [CLI installation](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md) · [CLI reference](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md) · [Application guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md) · [Manifest & signing guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md) · [File delivery](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md) |
| **Technical details** | [BSDIFF40 format](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/format.md) · [Generation scales](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md) · [Benchmarks](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/benchmarks.md) · [Compatibility](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) |
| **Project & releases** | [Changelog](https://github.com/BigSaltyMan/moonBSDiff/blob/master/CHANGELOG.md) · [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases) · [BSD-2-Clause License](https://github.com/BigSaltyMan/moonBSDiff/blob/master/LICENSE) · [Upstream & third-party notices](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/upstream.md) |
