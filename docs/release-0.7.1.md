# MoonBSDiff 0.7.1 release

- [Annotated tag v0.7.1](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.7.1) (`6ecaaa1744350d7c5f479313cc40cf08d7739c4e`) points to `76eda8be71cacd45e9b40c67ce133eccdc598be7`.
- [Full pre-release CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/45963708712) ran all eight jobs (`native`, 4 native CLI targets, source-bound asset collection, real BSDiff 4.3 reference interoperability, and larger-input policies) on `moonc v1.0.0-rc1+3c0520448` (`moon 0.1.20261126`) and succeeded 8/8.
- [GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.7.1) and [Mooncakes registry metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.7.1).
- [Release evidence](../testdata/release/0.7.1.json) and [member hashes](../testdata/release/0.7.1-members.json).

## Highlights

- **MoonBit `1.0.0-rc1` toolchain migration (`moonc v1.0.0-rc1+3c0520448`, `moon 0.1.20261126`)**: upgraded the entire library, CLI, Web Studio, examples, verification scripts, and 4-platform GitHub Actions CI matrix from `moonc v0.10.19+bee578715` to official `moonc v1.0.0-rc1+3c0520448` with zero compiler warnings under `--frozen --deny-warn` across `native`, `js`, and `wasm-gc`.
- **Zero-deprecation 1.0 stdlib & JSON depth-guard compatibility**: migrated `StringBuilder(capacity=...)`, `@string.parse_bigint`, and `@json.Json(...)`; replaced deprecated `@json.ParseError` constructor pattern matching (`Warning [0014]`) with `@json.Json(error)` inspection; and added explicit upfront `json_exceeds_max_depth` scanners preserving identical nesting-depth limits (`DepthLimitExceeded` and private-key redaction) under stack-safe 1.0 `@json.parse`.
- **Reproducible Wasm-GC example & studio metadata sync**: recorded independent Linux/WSL `1.0.0-rc1+3c0520448` Wasm-GC expectations (`3956` B, reproduced identically on Windows and CI) in `examples/wasm-update/manifest.json` and synchronized `cmd/studio` reported `studio_version` to `PRODUCER_VERSION` (`0.7.1`).

## Mooncakes

The [public 0.7.1 ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.7.1.zip) contains 55 files in 134,125 bytes. Its SHA-256 is `3b0465e84d429ef465994daec61b6e30f13d0c004bda4c5740f57ca47637bb27`, matching the audited Windows `git archive` export byte for byte. Thanks to `-c core.autocrlf=false` in `scripts/release_audit.py`, all 55 member files match the Linux CI candidate ZIP (`134,125` bytes, SHA-256 `67e21286c5137de9e31f1b5da9bb25c66497a59a94d503e24b7ae3d311bd8ad7`, differing only in OS ZIP container metadata) **55/55 raw byte for byte with zero CRLF differences**.

Both the Linux CI candidate consumer and a fresh isolated Windows `1.0.0-rc1+3c0520448` SDK installation from live Mooncakes (`BigSaltyMan/moonbsdiff@0.7.1`) passed the `0.7.1` probe (`scripts/release_consumer_070.mbt.in`, covering `analyze_patch`, `TrustStore` + `ReleaseCatalog` + `CatalogSignature`, `dir_diff` + `dir_apply_signed`, `apply_stream`, `apply_signed`, `plan_update`, and `restore`: `candidate=1 patch_bytes=162 target_bytes=1045 apply_patch_cap=131072`) across all three targets (`native`, `js`, and `wasm-gc`).

## Published CLI archives

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.1/SHA256SUMS) | 491 | `718e80161ea0c4abe149f04324ff79e1ddde9acb0ed523bcb78521b250c1aa62` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.1/build-info.json) | 13876 | `f410636b36a07a709d209380c61300b6cc7dd6a9bf581a4dd05544b3db0c5143` |
| [moonbsdiff-0.7.1-linux-arm64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.1/moonbsdiff-0.7.1-linux-arm64.tar.gz) | 596573 | `9c6938c57143deceee25290ebc740e0061943e27ec6c1311a6cb9ff6d2a5b216` |
| [moonbsdiff-0.7.1-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.1/moonbsdiff-0.7.1-linux-x86_64.tar.gz) | 654473 | `a110a1cef193546e4c40b5048e1371907674d984779452d2e681343f3d1aad29` |
| [moonbsdiff-0.7.1-macos-arm64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.1/moonbsdiff-0.7.1-macos-arm64.tar.gz) | 550066 | `6dc285fec8492db0c2b2b1d14d03e0e52001632c9780ede418664d8e2025e740` |
| [moonbsdiff-0.7.1-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.1/moonbsdiff-0.7.1-windows-x86_64.zip) | 495649 | `78315c4d0080d355818b8ce4e926a9a8dcf03ba753b1800ff7a30fea80cb4098` |

All six public downloads matched the CI Run `#45963708712` assets byte for byte. Both Windows (`x86_64`) and Ubuntu 24.04 WSL (`linux-x86_64`) extracted and ran their respective CI/public executables, reporting `moonbsdiff 0.7.1`, and both passed `scripts/run_update_demo.py` (`UPDATE DEMO PASS`) and `scripts/run_070_acceptance.py --skip-web` (`ACCEPTANCE 0.7.0 PASS`).
