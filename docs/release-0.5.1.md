# MoonBSDiff 0.5.1 release

- [Source and annotated tag](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.5.1) commit `e66edcf8c2bda8906c6f75594cdf3072e7532fcf`.
- [Full pre-release CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44495452496) ran via `workflow_dispatch` with `run_generation_scales=true`. All six jobs passed.
- [GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.5.1) and [Mooncakes registry metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.5.1).
- [Machine-readable release record](../testdata/release/0.5.1.json) and [ZIP member inventory](../testdata/release/0.5.1-members.json).

## Regression

- Native ran 161/161 tests. JS and Wasm-GC each ran 135/135 tests in CI and
  25/25 additional tests locally on the same commit. The extra selections were
  the full limits/inspect/header/format files and uncovered suffix, matching,
  generation, compression, bundle and route tests. The three targets passed
  check/build and the workflow checked formatting and generated interfaces.
- The 66,279-byte default patch restored exactly. The same patch failed under an
  explicit 65,536-byte cap. The Diff CRC and shared expanded-output limits
  still report their expected structured errors.
- Windows and Ubuntu each ran 114 Python CLI cases, including 34 in the main file suite.
  Each platform passed 9 private file contracts. Windows passed 2 additional
  stream contracts, and Ubuntu passed 4 stream and ext4 compatibility tests.
  The shell and filesystem steps assigned to the other OS were skipped by design.
  Ubuntu also delivered files on ext4 without /proc.
- Windows PE exports and Linux ELF symbol tables contained none of the five
  private test symbols. Fault injection still ran in the dedicated builds.
  CLI help tests distinguished a help flag from a literal path after `--`.
- The locked BSDiff 4.3 oracle and MoonBSDiff agreed byte for byte in all 138
  restorations, with 31 per direction on native and 19 each on JS and Wasm-GC.
- Both CLI jobs ran the update demo and unpacked their release archives for
  smoke testing. Ubuntu ran the memory and Wasm update examples.

Fresh native release measurements and both randomized CLI replays are in the
[scale artifact](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44495452496/artifacts/14514991459).
All restored outputs matched byte for byte. Patch sizes are in bytes.

| Input | Sparse | Periodic | Random |
| --- | ---: | ---: | ---: |
| 256 KiB | 188 | 165 | 263849 |
| 1 MiB | 197 | 168 | 1053978 |

Other benchmark steps verified stored records without retiming the benchmarks.
The [initial run](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44494692961)
stopped in the Linux Wasm example because its manifest lacked a 0.5.1 entry.
The final commit added the hashes from independent builds of both modules,
then passed the complete regression again.

## Mooncakes

The [public 0.5.1 ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.5.1.zip) contains 281 files in
619915 bytes. Its SHA-256 is `a36e156c39c0e48dd800031a97f8d51abf676c77ab6f57c2a9515ed684c2404d`,
matching the registry metadata and the Windows package from the clean source
export and official dry-run.

The Linux CI candidate ZIP SHA-256 is `e2492c7d51c5e4db96a25c5e5045b2a84503f959add287d87db28f8426293ab3`.
The ZIP entry order differs. Every member path and file SHA-256 matches the
public ZIP and the normalized source export.

The external CI candidate passed on native, JS and Wasm-GC. A separate Windows
project and fresh registry cache installed exact BigSaltyMan/moonbsdiff@0.5.1 on
native. The consumer used the public manifest API and read the 131072-byte
default cap. It selected candidate 1 and restored all 1045 expected bytes.

## Published CLI archives

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.1/SHA256SUMS) | 287 | `837000df3b353a032730e3348bd46af4260bc644c29656522affef2580ddf06e` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.1/build-info.json) | 7090 | `cce1dca90fe7ce9667854631351237555d8d6a5a0562b2239ac10d0ec3fd6edd` |
| [moonbsdiff-0.5.1-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.1/moonbsdiff-0.5.1-linux-x86_64.tar.gz) | 438518 | `718808790bd3300aeaad3aa1fdc0e096e32565aa1d26543f1d4b8dc920a7ac2c` |
| [moonbsdiff-0.5.1-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.1/moonbsdiff-0.5.1-windows-x86_64.zip) | 309073 | `81678ae455b8de6d04f50d678e920a11fa3881d5a49dd93f200434290a2a4999` |

All four public downloads matched the CI assets byte for byte. Windows and
Ubuntu 24.04 WSL ran the executable extracted from the published archive.
Both reported `moonbsdiff 0.5.1` and showed `--max-download-bytes` in
`manifest plan --help` with exit 0.

## README erratum

The published snapshot uses a raising assertion in a plain MoonBit main in the
README quick start. The corrected example compares the restored bytes directly.
That [example](https://github.com/BigSaltyMan/moonBSDiff/blob/9a14f4e9020256a757a94590adb6d026ce5fd427/README.md#moonbit-library)
compiled and ran against the public 0.5.1 package. The annotated tag and public
package continue to identify the audited release snapshot.
