# MoonBSDiff 0.5.2 release

- [Annotated tag v0.5.2](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.5.2) points to `c6911233d3b4d8e93165fedd162bf41522417cf8`.
- [Full pre-release CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44543952823) ran all six jobs via `workflow_dispatch` with `run_generation_scales=true`.
- [GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.5.2) and [Mooncakes registry metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.5.2).
- [Release evidence](../testdata/release/0.5.2.json) and [member hashes](../testdata/release/0.5.2-members.json).

## Regression

- Native passed 162 tests. JS and Wasm-GC each passed 135 tests in CI and 25 additional applicable tests locally on the same commit. The local selections cover limits, format, inspection, suffix and matching, generation, compression, bundles and routing. All three targets passed check and build.
- Windows and Ubuntu each passed 116 Python CLI cases and 9 private file I/O contracts. Windows passed 2 additional stream contracts. Ubuntu passed 4 stream and ext4 compatibility contracts and separately tested real unprivileged ext4 delivery without `/proc`. CI skipped the other platform's steps as configured. Both CLI jobs ran the update demo and validated their release archives. Ubuntu also ran the memory and Wasm update examples.
- Windows and Ubuntu each generated six boundary patches, with `CDE`, `CCD` and final `CC` at level 1 and default level 9. Each passed deep inspection, byte-for-byte restoration and independent Python bzip2 decompression with a complete stream and no trailing data. Native generation limit tests passed, and replaying the encoder adaptation reproduced all four locked files.
- The target manifest described a 2532-byte direct patch. At a 204-byte per-patch cap, planning selected 204 + 164 = 368 bytes, and both chain commands accepted the same manifest and cap. The delivered 2048 bytes matched the independent target. A 203-byte cap and an incorrect target SHA-256 each failed without delivering a file.
- The locked BSDiff 4.3 oracle agreed byte for byte in all 138 restorations, with 31 per direction on native and 19 each on JS and Wasm-GC. The compression probe ran all nine levels and passed two separate comparisons with upstream `bspatch`.

[Fresh large-input results](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44543952823/artifacts/14539850852) include six generation and restoration cases and the two random-sample CLI replays. Every restored output matched byte for byte. Patch sizes are in bytes.

| Input | Sparse | Periodic | Random |
| --- | ---: | ---: | ---: |
| 256 KiB | 188 | 165 | 263849 |
| 1 MiB | 197 | 168 | 1053978 |

The other benchmark steps checked stored records. The README quick-start example compiled and ran from its exact listing against the candidate package in an external workspace.

## Mooncakes

The [public 0.5.2 ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.5.2.zip) contains 289 files in 654960 bytes. Its SHA-256 is `91651b17251b2a092841bc19872bd106d75d8b4984cb0f42185bc9204153e960`, matching the registry checksum and the Windows package from the clean Git export. The Linux CI candidate ZIP has SHA-256 `f5921103dc4151b966d45654dbcae0359d363b0227c6620d07da7c67b8646859`. ZIP entry order differs, and every member path and file SHA-256 agrees with both the public ZIP and the clean export.

The external CI consumer passed on native, JS and Wasm-GC. A fresh Windows project and cache independently installed exact `BigSaltyMan/moonbsdiff@0.5.2` from the registry. The native manifest probe read the 131072-byte cap and restored 1045 expected bytes. A level-1 `CCD` boundary patch generated with the installed library passed deep inspection and restored all 100002 expected bytes.

## Published CLI archives

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.2/SHA256SUMS) | 287 | `8b96d34095ca7b1698eadb8f0abc31c340364af7054b966ef51be2d211c2c690` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.2/build-info.json) | 7090 | `372afec87e625380234d604913a606eee8aa1e7f1abf7345a3cef205b7a3dbe6` |
| [moonbsdiff-0.5.2-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.2/moonbsdiff-0.5.2-linux-x86_64.tar.gz) | 438976 | `a92aa227552a7b476c4e5a00250235ab9a7661ec4c425c3dcf0e524c6cdc64d0` |
| [moonbsdiff-0.5.2-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.2/moonbsdiff-0.5.2-windows-x86_64.zip) | 309182 | `140cdcf31033ab660cb8f4660b4fae1d3314089921438baf8e219962fccca812` |

All four public downloads matched the CI assets byte for byte. Windows and Ubuntu 24.04 WSL ran the executable extracted from their public archive and both reported `moonbsdiff 0.5.2`. The Windows binary also delivered the two-hop route at the 204-byte cap with the direct target manifest. Its 2048-byte output matched the independent target and had SHA-256 `66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6`.
