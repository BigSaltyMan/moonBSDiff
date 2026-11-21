# MoonBSDiff 0.5.4 release

- [Annotated tag v0.5.4](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.5.4) points to `bac93622df18bf70cf49a89b7f48e40d7f140e4b`.
- [Full pre-release CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44915136201) ran all six jobs via `workflow_dispatch` with `run_generation_scales=true`.
- [GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.5.4) and [Mooncakes registry metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.5.4).
- [Release evidence](../testdata/release/0.5.4.json) and [member hashes](../testdata/release/0.5.4-members.json).

## Highlights

- **bzip2 Huffman Kraft repair**: fixed length-limit Kraft repair in `internal/bzip2` when an uncapped Huffman tree reaches depth 23 or greater, preventing oversubscribed tables on skewed symbol distributions. Added unit tests covering depths 23–25, leading zero weights, and a full 258-symbol alphabet, plus a level-9 CLI regression verifying exact Kraft completeness and maximum length 20.
- **Core diff matching and suffix-array optimization**: added LCP-skipping binary search with right-endpoint probing and boundary LCP reuse in `matching.mbt`, and replaced the redundant second-key counting sort in `suffix_array.mbt` with an initial single-pass length-1 sort plus linear second-key placement. Repeated-prefix inputs (2 KiB and larger) stay within default `Limits::for_diff()` budgets while producing byte-identical patches.
- **Mooncakes library package trimming**: added `.moonignore` to ship only the 49 runtime source, interface, root metadata/license, and `internal/bzip2` provenance files (77992 bytes, 88.47% smaller than 0.5.3's 676,237-byte / 292-file package), upgraded `scripts/release_audit.py` to two-layer source/package policy auditing, updated `README.md` `docs/` links to absolute GitHub URLs, and removed the test-only `base64` dependency from `manifest/moon.pkg`.

## Regression

- Native passed 169 tests. JS and Wasm-GC each passed 137 tests in CI across compression, apply, inspect, manifest, suffix, matching, diff, index, options, and diff-resource suites. All three targets passed `moon check --deny-warn` and `moon build`.
- Windows and Ubuntu each passed 118 Python CLI cases and 9 private file I/O contracts. Windows passed 2 additional stream contracts; Ubuntu passed 4 stream and ext4 compatibility contracts and tested unprivileged ext4 delivery without `/proc`. Both CLI jobs ran the update demo and validated their release archives; Ubuntu also ran the memory and Wasm update examples against the independently verified `0.5.4` Wasm hashes.
- Windows and Ubuntu each passed the level-9 Huffman Kraft regression (`Huffman Kraft at level 9: max lengths by block [[[4, 3]], [], [[20, 8, 8, 8, 7, 7]]], 869442 bytes restored`) and all six RLE block-boundary cases (`CDE`, `CCD`, `CC` at levels 1 and 9). Replaying `internal/bzip2/encoder-changes.patch` reproduced all four locked upstream files.
- The locked BSDiff 4.3 oracle agreed byte for byte across the full bidirectional interoperability matrix (native, JS, and Wasm-GC).

[Fresh large-input results](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44915136201/artifacts/14711187093) include six generation and restoration cases and two random-sample CLI replays. Every restored output matched byte for byte, and all six patch sizes match `0.5.3` identically (in bytes):

| Input | Sparse | Periodic | Random |
| --- | ---: | ---: | ---: |
| 256 KiB | 188 | 165 | 263849 |
| 1 MiB | 197 | 168 | 1053978 |

## Mooncakes

The [public 0.5.4 ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.5.4.zip) contains 49 files in 77992 bytes. Its SHA-256 is `fa7e0863ec0cbe35a4d9c008d2d75587f956750e7824aea43bfc913301495c5b`, matching the registry checksum and the Windows package exported with `core.autocrlf=false`. The Linux CI candidate ZIP has SHA-256 `4b9611589745937d7e2bd5f87e819cf7ab0923d221c37b0a8098a47315cc2187` (same 77992 bytes and 49 files); only ZIP entry ordering/metadata differs, and every member path and file SHA-256 agrees byte for byte with both the public ZIP and the clean export (`canonical_member_map_sha256`: `f9e3f4e20a2dfe83ee5ecd52f744e14b1c7dc903fba54215bad521499c573552`).

The external CI candidate consumer passed on native, JS, and Wasm-GC. A fresh Windows project and isolated SDK cache independently installed exact `BigSaltyMan/moonbsdiff@0.5.4` from Mooncakes and passed the manifest probe (`apply_patch_cap=131072`, restoring 1045 expected bytes) on all three targets (`native`, `js`, `wasm-gc`), and compiled and ran the exact `README.md` quick-start example against the public package.

## Published CLI archives

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.4/SHA256SUMS) | 287 | `e9cacd8b8a7c3e5b451c23fb725969b6f70be1d9a228cb6643e69122e852aa60` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.4/build-info.json) | 7090 | `79140dbe9905ce8bb6959fadca8113e1d3d249f0ef0b6221e04df2d9c90b439c` |
| [moonbsdiff-0.5.4-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.4/moonbsdiff-0.5.4-linux-x86_64.tar.gz) | 438873 | `cae26fa8427c8530a640df045993109284a3ce92f0ad81809d1a76c740e56d6c` |
| [moonbsdiff-0.5.4-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.4/moonbsdiff-0.5.4-windows-x86_64.zip) | 305615 | `2dbd1915da0c44bf32ac14bac1001909b5d54c4bb5b4eb7638be85946e90cb96` |

All four public downloads matched the CI assets byte for byte. Windows and Ubuntu 24.04 WSL extracted and ran their respective public executables, and both reported `moonbsdiff 0.5.4`.
