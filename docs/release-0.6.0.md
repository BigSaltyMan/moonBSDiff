# MoonBSDiff 0.6.0 release

- [Annotated tag v0.6.0](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.6.0) (`e6341c0cdfca8f9a2a7f5173736148233c0f5e4b`) points to `e362c180885566a9ddedf7f3d774fda5ac95324c`.
- [Full pre-release CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/45355255462) ran all eight jobs (`native`, 4 native CLI targets, source-bound asset collection, real BSDiff 4.3 reference interoperability, and larger-input policies) and succeeded 8/8.
- [GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.6.0) and [Mooncakes registry metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.6.0).
- [Release evidence](../testdata/release/0.6.0.json) and [member hashes](../testdata/release/0.6.0-members.json).

## Highlights

- **Detached Ed25519 manifest signing & verification (cross-target library & CLI)**: kept BSDIFF40 patches and Schema 1 manifests unchanged while adding optional publisher authentication via detached Ed25519 signature files (`moonbsdiff-manifest-ed25519-v1\x00` domain separation, strict `4096`-byte JSON envelopes, and strict RFC 8032 canonical point/scalar/torsion validation). Added `PublicKey`, `PrivateKey`, `ManifestSignature`, `SignatureError`, `SignedManifestError`, `verify_raw_signature`, `verify_manifest_signature`, `verify_manifest_signature_bytes`, `validate_manifest_schema`, `prepare_signed`, and `apply_signed` in `BigSaltyMan/moonbsdiff/manifest`, plus CLI `manifest keygen` / `sign` / `verify-sig` and paired `--public-key` + `--signature` enforcement on `verify`, `patch`, and `install-full`.
- **Diff common prefix/suffix fast path & cross-target `apply_stream`**: standalone `diff` and `diff_with_options` automatically trim shared leading/trailing byte runs (`>= 64` bytes) while `DiffIndex::diff` preserves full-SA matching for all inserts and edits and applies the zero-search fast path only on identical or pure-delete pairs. Added cross-target `apply_stream` (`StreamApplyStage`, `StreamApplyError`, `DeepPatchInfo`) in `BigSaltyMan/moonbsdiff` for Native, JS, and Wasm-GC in bounded `<= 4096`-byte chunks, and delegated CLI streaming to it.
- **macOS (`arm64`) & Linux `arm64` native CLI releases**: expanded CI-built native CLI targets and release packaging from 2 to 4 platforms (`windows-x86_64`, `linux-x86_64`, `linux-arm64`, `macos-arm64`), publishing 6 assets (`4 archives + SHA256SUMS + build-info.json`). Intel macOS (`macos-x86_64`) is not built in CI because upstream MoonBit `0.10.19` does not publish `darwin-x86_64` native toolchains.
- **Bilingual README (`README.md` + `README.zh-CN.md`)**: reorganized English and Simplified Chinese READMEs with absolute GitHub URLs for Mooncakes rendering and added `README.zh-CN.md` to the two-layer release package audit allowlist (`52` packaged members total).

## Mooncakes

The [public 0.6.0 ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.6.0.zip) contains 52 files in 98,660 bytes. Its SHA-256 is `a88e9b0939225c7cf4b4e2a0140b9f8c855743fac4fa6720ccea7d6d494e68de`, matching the audited Windows `git archive` export byte for byte. The Linux CI candidate ZIP (`98,220` bytes, SHA-256 `7f79eb35e9470576f16c9523b35ef457d4d130c0c27db770eb45c4538e8ac28f`) has identical member paths and content across all 52 files after CRLF-to-LF normalization (30 text files without explicit LF `.gitattributes` entries were exported with CRLF by Windows `git archive` under `core.autocrlf=true`; all 22 LF-pinned files matched raw byte for byte).

Both the Linux CI candidate consumer and a fresh isolated Windows SDK installation from live Mooncakes (`BigSaltyMan/moonbsdiff@0.6.0`) passed the `0.6.0` probe (`scripts/release_consumer_060.mbt.in`, covering `diff`, `apply_stream`, `PrivateKey::from_seed`, `sign_manifest`, `apply_signed`, `plan_update`, and `restore`: `candidate=1 patch_bytes=162 target_bytes=1045 apply_patch_cap=131072`) across all three targets (`native`, `js`, and `wasm-gc`).

## Published CLI archives

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.6.0/SHA256SUMS) | 491 | `c733dea84c70b1ad9364d19af0142bb42f1d0b86dc867185a1d6275fda4498a9` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.6.0/build-info.json) | 13867 | `54383061c17476b34bfcee56cfc93af507be76e5ea8cf0f589bec96789c86cf8` |
| [moonbsdiff-0.6.0-linux-arm64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.6.0/moonbsdiff-0.6.0-linux-arm64.tar.gz) | 459501 | `af02db989e50d172ecd747dc113488dae1336d0e6f4083f0a1d8bee101a44ee7` |
| [moonbsdiff-0.6.0-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.6.0/moonbsdiff-0.6.0-linux-x86_64.tar.gz) | 508013 | `08103621997ad536ef5ee3c6b0653591c6b1989c71a0fbbcfe2a8e141d1ef78a` |
| [moonbsdiff-0.6.0-macos-arm64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.6.0/moonbsdiff-0.6.0-macos-arm64.tar.gz) | 389869 | `cb6765a2ace89d26a39f424020f838a2b8bd3a2231ba9c41e8aaa09d3aad7cee` |
| [moonbsdiff-0.6.0-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.6.0/moonbsdiff-0.6.0-windows-x86_64.zip) | 369868 | `78ef6137a3b4273f9b5ebd54f1e1686b6db89e06dbb731a66d2affa2ef47f9e1` |

All six public downloads matched the CI Run `#45355255462` assets byte for byte. Windows (`x86_64`) and Ubuntu 24.04 WSL (`linux-x86_64`) extracted and ran their respective public executables, both reporting `moonbsdiff 0.6.0`, and the public Windows executable passed `scripts/run_update_demo.py` (`UPDATE DEMO PASS`).
