# MoonBSDiff 0.5.0 release

## Published identities

- [v0.5.0 GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.5.0) and [tagged source](https://github.com/BigSaltyMan/moonBSDiff/tree/v0.5.0). The annotated tag resolves to `4ecb36fbda27794cbcf7abcfed3cb9edc6ac01db`.
- [Source CI 44466655432](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/44466655432) passed all six jobs. This run supplied both CLI archives and their two checksum/provenance files.
- [Mooncakes 0.5.0 metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.5.0) and [public ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.5.0.zip). The package has **604017 bytes** and **277 members** with SHA-256 `b5cdb9e9c7a6f4a5c1fde42040dfc443f39342d1aa0794c3fd3ce68a26441a79`.
- [Machine-readable publication results](../testdata/release/0.5.0.json) and [complete member inventory](../testdata/release/0.5.0-members.json).

## Package and independent consumers

Moon published from a clean Git export outside the checkout after an official
dry run. The public ZIP matches the normalized Windows candidate byte for
byte. The Linux CI candidate has a different ZIP entry order, with SHA-256
`6e32b894a59edd061e6424bca7ac1ad3e6c280e6e1b32907e4f98b7d4172ea8b`. All 277 member paths and file bytes agree
across the CI candidate, Windows candidate and public ZIP.

For canonical comparison, the Windows export used process-scoped
`core.autocrlf=false`. No repository or global Git line-ending configuration
changed. The member inventory hashes each file and the sorted compact member
map.

- Windows fresh registry project and cache passed native, JS and Wasm-GC
  using exact `BigSaltyMan/moonbsdiff@0.5.0`.
- Ubuntu 24.04 WSL fresh registry project and cache passed the native consumer.
- The Windows local and Linux CI external candidate consumers passed all three
  targets. The registry runs independently checked the installed package files
  against the clean release export and confirmed the resolved version.

The 0.5.0 probe imports the public `manifest` subpackage. It makes a BSDIFF40
bundle, prepares its manifests, selects candidate index 1 with a 168-byte patch
and restores all 1045 expected bytes.

## Public CLI archives

| Asset | Size in bytes | SHA-256 |
| --- | ---: | --- |
| [SHA256SUMS](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.0/SHA256SUMS) | 287 | `b81e73501c30cddbeeebb94184e39c835311ba0c03f278a36766e2d213ee0ee8` |
| [build-info.json](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.0/build-info.json) | 7090 | `8543d540a05dfe19ab6e9a0987af65644759d8005d02359e5256fce45a6a5947` |
| [moonbsdiff-0.5.0-linux-x86_64.tar.gz](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.0/moonbsdiff-0.5.0-linux-x86_64.tar.gz) | 439835 | `0299e0f3a39ca19afbba0e2fde7b911b07977a25e721bdf12fb87b1c4dbb53cf` |
| [moonbsdiff-0.5.0-windows-x86_64.zip](https://github.com/BigSaltyMan/moonBSDiff/releases/download/v0.5.0/moonbsdiff-0.5.0-windows-x86_64.zip) | 311262 | `dce1430e3e2cb5262839d58497bd278a7b16bf7b340447cf3dbadc898731985d` |

All four public downloads match the CI assets. Each extracted executable
reports `moonbsdiff 0.5.0`. Windows and Ubuntu 24.04 WSL both ran the
[update demo from the tag](update-demo.md) using those public binaries.
They selected **2048**, **368** and **0** download bytes, then delivered
a file that matched the independent 2048-byte target byte for byte.
Its SHA-256 was `66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6`.

The separate CLI jobs run the same demo from their build directories.
Archive validation also checks the version and a manifest round trip from
a fresh extraction. See [installation and platform requirements](cli-install.md)
for Windows x86_64 and Linux x86_64.

## Scope

Version 0.5.0 includes the manifest package, deep inspection, streaming
verification and delivery, update planning, and offline patch-chain recovery.
See [compatibility](compatibility.md) and [upstream licenses](upstream.md).
[The 0.4.0 record](release-0.4.0.md) retains the previous source, package and
CLI identities. This evidence record was written after publication; the
tag continues to identify the audited release source.
