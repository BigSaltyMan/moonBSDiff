# MoonBSDiff 0.5.3 release

- [Annotated tag v0.5.3](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.5.3) points to `ff98b94e8c0084bab4d5faaf4fc98f2031c5a56a`.
- [Full pre-release CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44668535474) ran all six jobs via `workflow_dispatch` with `run_generation_scales=true`.
- [GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.5.3) and [Mooncakes registry metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.5.3).
- [Release evidence](../testdata/release/0.5.3.json) and [member hashes](../testdata/release/0.5.3-members.json).

## Regression

- Native passed 162 tests. JS and Wasm-GC each passed 135 tests in CI and 25 additional applicable tests locally on the same commit. The local selections cover limits, format, inspection, suffix and matching, generation, compression, bundles and routing. All three targets passed check and build.
- Windows and Ubuntu each passed 117 Python CLI cases and 9 private file I/O contracts. Windows passed 2 additional stream contracts. Ubuntu passed 4 stream and ext4 compatibility contracts and separately tested real unprivileged ext4 delivery without `/proc`. CI skipped the other platform's steps as configured. Both CLI jobs ran the update demo and validated their release archives. Ubuntu also ran the memory and Wasm update examples.
- Windows and Ubuntu each generated six boundary patches, with `CDE`, `CCD` and final `CC` at level 1 and default level 9. Each passed deep inspection, byte-for-byte restoration and independent Python bzip2 decompression with a complete stream and no trailing data. Native generation limit tests passed, and replaying the encoder adaptation reproduced all four locked files.
- The ordinary planning regression passed on Windows and Ubuntu. At a 204-byte cap, the direct target manifest selected the 204- and 164-byte steps. Adding that manifest as a positional candidate rejected its 2532-byte patch. A 203-byte cap rejected the first step. Both target size limits remained active.
- The target manifest described a 2532-byte direct patch. At a 204-byte per-patch cap, planning selected 204 + 164 = 368 bytes, and both chain commands accepted the same manifest and cap. The delivered 2048 bytes matched the independent target. A 203-byte cap and an incorrect target SHA-256 each failed without delivering a file.
- The locked BSDiff 4.3 oracle agreed byte for byte in all 138 restorations, with 31 per direction on native and 19 each on JS and Wasm-GC. The compression probe ran all nine levels and passed two separate comparisons with upstream `bspatch`.

[Fresh large-input results](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44668535474/artifacts/14599276735) include six generation and restoration cases and the two random-sample CLI replays. Every restored output matched byte for byte. Patch sizes are in bytes.

| Input | Sparse | Periodic | Random |
| --- | ---: | ---: | ---: |
| 256 KiB | 188 | 165 | 263849 |
| 1 MiB | 197 | 168 | 1053978 |

The other benchmark steps checked stored records. The README quick-start example compiled and ran from its exact listing against the candidate package in an external workspace.

## Mooncakes

The [public 0.5.3 ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.5.3.zip) contains 292 files in 676237 bytes. Its SHA-256 is `cca450a2b5f2013cfa7414b4e3251eb3deffd2fde43d2f9eb56a2f123f54c227`, matching the registry checksum and the Windows package from the clean Git export. The Linux CI candidate ZIP has SHA-256 `939997bceebd65d0bb0dfba6b85b7b8d4bc465401b1e7460ad9e56270abce83e`. ZIP entry order differs, and every member path and file SHA-256 agrees with both the public ZIP and the clean export.

The external CI consumer passed on native, JS and Wasm-GC. A fresh Windows project and cache independently installed exact `BigSaltyMan/moonbsdiff@0.5.3` from the registry. The native manifest probe read the 131072-byte cap and restored 1045 expected bytes.

## Published CLI archives

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.3/SHA256SUMS) | 287 | `3d53afd42c005dc83f46039bbab1f7c64c24484363415fa278cbf82e934f94d2` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.3/build-info.json) | 7090 | `6bfa5d20119f9f8057656da665b65b5709a2cd2a9dc26f6f06fd358f6493fb32` |
| [moonbsdiff-0.5.3-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.3/moonbsdiff-0.5.3-linux-x86_64.tar.gz) | 438955 | `40f247b7d785bc09ef9850a2ac01a7276fdf04de977e659c2be5515c8091a87a` |
| [moonbsdiff-0.5.3-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.3/moonbsdiff-0.5.3-windows-x86_64.zip) | 309172 | `8260a6241fb63bf108bdd0c8097755695bf4de58818a9338ef8b70351d2410b9` |

All four public downloads matched the CI assets byte for byte. Windows and Ubuntu 24.04 WSL ran the executable extracted from their public archive and both reported `moonbsdiff 0.5.3`. The Windows binary ran ordinary planning at a 204-byte cap with the direct target manifest. It returned `v1-to-v2.json` and `v2-to-v3.json` in order with `total_patch_bytes` equal to `"368"`. Adding the target manifest as a positional candidate exited 1 with empty stdout.

> moonbsdiff: manifest plan 'v1-to-v3.json': manifest limits: patch/max_patch_bytes declared size 2532 exceeds limit 204
