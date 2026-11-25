# MoonBSDiff 0.7.0 release

- [Annotated tag v0.7.0](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.7.0) (`0ef381ec6a4cd0c9d0b4b73eacd42ba6155e5928`) points to `3927124312789a9d0cb44de530787851365a6986`.
- [Full pre-release CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/45541918470) ran all eight jobs (`native`, 4 native CLI targets, source-bound asset collection, real BSDiff 4.3 reference interoperability, and larger-input policies) and succeeded 8/8.
- [GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.7.0) and [Mooncakes registry metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.7.0).
- [Release evidence](../testdata/release/0.7.0.json) and [member hashes](../testdata/release/0.7.0-members.json).

## Highlights

- **Linear-time `O(n)` SA-IS suffix-array engine**: upgraded `build_suffix_array` and `build_suffix_array_view` (`suffix_array.mbt`) from `O(n log n)` prefix-doubling to linear-time `O(n)` SA-IS while preserving exact BSDIFF40 suffix order, byte-identical patches, and bounded `SortBudget` accounting across recursive levels (`4.49x`–`4.92x` less `sort_work` and `4.33x`–`6.05x` faster SA construction on 256 KiB / 1 MiB periodic inputs).
- **Preflight patch forensics & decompression-bomb auditor (`analyze_patch` / `inspect --analyze`)**: added cross-target (`native`/`js`/`wasm-gc`) `analyze_patch(Bytes, Limits) -> Result[PatchAnalysis, BsdiffError]` (`analyze.mbt`) and CLI `inspect --analyze [--json]`, computing compressed stream breakdown, overflow-safe ratios, seek stats, first 64 control samples, validated minimal `required_limits`, and risk flags (`HIGH_EXPANSION_RATIO`, `PATCH_LARGER_THAN_OUTPUT`, `HIGH_EXTRA_RATIO`, `EXCESSIVE_CONTROL_DENSITY`, `ZERO_OUTPUT_NONTRIVIAL_PATCH`).
- **Multi-key `TrustStore`, signed `ReleaseCatalog` & signed multi-hop chains**: added zero-downtime key rotation (`TrustStore`, repeatable `--public-key` up to 64 keys), fail-closed `verify_signed_candidates`, Schema 1 `ReleaseCatalog` with domain-separated `CatalogSignature` (`moonbsdiff-catalog-ed25519-v1\x00`), anti-replay (`min_catalog_version`), anti-downgrade Dijkstra routing (`manifest catalog sign|verify|plan`), and signed `verify-chain` / `patch-chain`.
- **Whole-directory delta bundles (`dir_diff` / `dir_apply` / `dir_apply_signed` & CLI `dir-*`)**: added Schema 1 `DirManifest`, canonical UTF-8 `tree_sha256`, unchanged/rename deduplication, BSDIFF40 vs full-file fallback, domain-separated `DirManifestSignature`, and CLI `dir-diff` / `dir-verify` / `dir-patch` with symlink/reparse-point, case-collision, and no-overwrite preflight.
- **Adversarial red-team security hardening**: added pre-BWT `StreamReader` decompression metering blocking BWT decompression bombs in `analyze_patch`, `inspect_deep`, and `apply_stream`; strict RFC 3986 ASCII authority & strict UTF-8 catalog URI checks; unique `Patched.from_path`, per-file `Limits`, and cross-action `cloned_bytes <= max_output_bytes` limits in `dir_bundle.mbt`; zero-alloc linear prefix-collision validation (`44.8x` faster on 430 disjoint deep paths); and full Unicode 16.0 case-folding + Windows `\\.\` / trailing dot-space / extended DOS device rejection in `cmd/main/native_io.c`.
- **Zero-backend Web Studio & 0.7.0 acceptance runner**: added 4-tab MoonBit JS ESM workbench (`cmd/studio/` + `examples/web-studio/`) verified by `scripts/test_web_studio.py` (`10/10` Node ESM tests) and deterministic end-to-end acceptance runner `scripts/run_070_acceptance.py`.

## Mooncakes

The [public 0.7.0 ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.7.0.zip) contains 55 files in 133,244 bytes. Its SHA-256 is `1e39265cabe862dfa284cdf5de9a1734b86fb96b6e39d6371df24595fb3b32ac`, matching the audited Windows `git archive` export byte for byte. Thanks to `-c core.autocrlf=false` in `scripts/release_audit.py`, all 55 member files match the Linux CI candidate ZIP (`133,244` bytes, SHA-256 `df3ecef3b1a87fc33530902c3dff093ce81c415dd1a8b07e45e8ea2a493ac0c7`, differing only in OS ZIP container metadata) **55/55 raw byte for byte with zero CRLF differences**.

Both the Linux CI candidate consumer and a fresh isolated Windows SDK installation from live Mooncakes (`BigSaltyMan/moonbsdiff@0.7.0`) passed the `0.7.0` probe (`scripts/release_consumer_070.mbt.in`, covering `analyze_patch`, `TrustStore` + `ReleaseCatalog` + `CatalogSignature`, `dir_diff` + `dir_apply_signed`, `apply_stream`, `apply_signed`, `plan_update`, and `restore`: `candidate=1 patch_bytes=162 target_bytes=1045 apply_patch_cap=131072`) across all three targets (`native`, `js`, and `wasm-gc`).

## Published CLI archives

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.0/SHA256SUMS) | 491 | `a2af8b6385cb7d6db26f1283de724906109bc4faa36dc4533df6449d732ad4f7` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.0/build-info.json) | 13865 | `4fc8ce3ac228ac0a837272a8e52228464c4186af440377fbf06a699cf18f9ff5` |
| [moonbsdiff-0.7.0-linux-arm64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.0/moonbsdiff-0.7.0-linux-arm64.tar.gz) | 594586 | `3b94394afa5106855e5c56db3a7ff3872c8dab6e0887df33b243e0cf3c8d002e` |
| [moonbsdiff-0.7.0-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.0/moonbsdiff-0.7.0-linux-x86_64.tar.gz) | 648451 | `0c15acbae0823641f417e87314226b5f9fb57b5deff254ce6af47e266f2ab184` |
| [moonbsdiff-0.7.0-macos-arm64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.0/moonbsdiff-0.7.0-macos-arm64.tar.gz) | 549231 | `19db8af6001ef40b8bc058ec65e5ad03d6f447f3f8360906d26bc0de42327c53` |
| [moonbsdiff-0.7.0-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.7.0/moonbsdiff-0.7.0-windows-x86_64.zip) | 497093 | `0d35559a410138edd50ab59f64598b467ab1c3da70577547113760d0cd28d96a` |

All six public downloads matched the CI Run `#45541918470` assets byte for byte. Windows (`x86_64`) and Ubuntu 24.04 WSL (`linux-x86_64`) extracted and ran their respective public executables, both reporting `moonbsdiff 0.7.0`, and the public Windows executable passed both `scripts/run_update_demo.py` (`UPDATE DEMO PASS`) and `scripts/run_070_acceptance.py --skip-web` (`ACCEPTANCE 0.7.0 PASS`).
