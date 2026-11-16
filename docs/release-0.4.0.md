# MoonBSDiff 0.4.0 release

## Published identities — post-publication record

Published 2026-11-16. This section and the machine-readable
[0.4.0 evidence](../testdata/release/0.4.0.json) were added **after** publication;
they are not members of the frozen public package and do not change its source.

- Release source and annotated v0.4.0 target:
  `e39e66f1270c0f4e37cb14fcfc5739edc46d1798`.
- [Source CI 43877720043](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/43877720043):
  all six jobs passed. CLI binaries came from exactly this run; later documentation
  CI artifacts are not substituted for those public binaries.
- [Formal GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.4.0),
  title MoonBSDiff v0.4.0, neither draft nor prerelease.
- Public Mooncakes package: **500504 bytes**, **236 files**, SHA-256
  `2e22054e65ebcb862e67bacb52126b24bdffd34a35564aa533edebf8868fc66d`.
  Anonymous download, registry checksum and audited Windows-produced candidate
  agree exactly; all package-member bytes were audited against that source's
  clean Git export. The registry index records both 0.1.0 and 0.4.0 checksums.
- Windows external candidate **and registry** consumption passed native, JS and
  Wasm-GC using fresh caches and independent project/data. Registry consumption
  had no workspace/path override or copied dependency cache.
- Linux CI external **candidate** consumption passed all three targets. Its
  independently produced candidate container SHA is
  `51e585a81b006dec8d089ed2f15db7109e161f93d63d96a886e8defe36e7acc5`;
  it is not the public package's container identity.
- Linux local **registry** consumption remains incomplete: fresh registry-index
  clone failed with exit 128, `Recv failure: Connection reset by peer`, including
  a process-scoped HTTP/1.1 retry. It reached no target check/build/run. Linux
  candidate or CLI success does not substitute for registry consumption.

| Public CLI archive | Bytes | SHA-256 |
| --- | ---: | --- |
| moonbsdiff-0.4.0-windows-x86_64.zip | 262237 | b1534a22c38e2ae5eb6ca576ffba92eb5b4e97cf014a85f013422cf78b4fef8e |
| moonbsdiff-0.4.0-linux-x86_64.tar.gz | 381247 | dd2242550f5cfc0f95b65270a58f38a4edd224987e03cab8f94b8a6dd0c4305f |

Both archives, build-info.json and SHA256SUMS were anonymously re-downloaded
from the formal Release and matched the verified CI bytes. Archive execution
was performed once per platform in that CI, including manifest roundtrip and
stream/JSON recovery. Linux actual ABI requires highest symbol GLIBC_2.34,
loader /lib64/ld-linux-x86-64.so.2 and libc.so.6, tested on Ubuntu 26.04.1;
Windows was tested on Server 2025 with the system DLL imports recorded in
build-info.json. This does not certify all older platforms.

Preparation commit `6f558f35f437f91b97921cb0b6fad780133ea8ee` initially exposed
missing version-specific Wasm expectations. The release-source fix adds only
independently compiled 0.4.0 expectations; normalizing its single custom-name
version string reproduces each fixed 0.2.0 whole-file hash. No module source,
algorithm or format was changed. A first Windows fresh-index clone failed;
a new clean attempt passed. These failed attempts are not reported as successes.
Official publish validation required dependency synchronization in its own fresh
package extraction; --frozen was therefore not used for the successful dry-run
or actual publish. The final public package bytes remained unchanged by both.

Old v0.1.0/v0.2.0 tag objects, Release IDs and asset identities were re-read and
matched the preflight snapshot. The fresh public registry index retains the
original 0.1.0 checksum. No old release was moved or replaced. No feature, API,
Limits factory, codec dependency or copied decoder change occurred here.

### Metadata endpoint caution

The website metadata endpoint can return **latest-version** data even when a
version-like path or query is supplied. Do not use that URL alone as immutable
old-version evidence. The public versioned ZIP, SHA-256 and version-specific
registry index entry establish exact package identity. The metadata used for
this publication actually returned version 0.4.0 with the matching checksum.
The consumer check rejects an unexpected returned version rather than accepting
HTTP success. Historic records retain their original observation dates.

## Prepared release scope (included in the package)

Prepared 2026-11-16 from the frozen feature baseline
`4e9dbe84b4fd67d8e876788767ae1eb1e1236187`. Library and both CLI distributions
must bind to the same release source commit. This document describes the prepared
release; it is not itself proof that an upload has happened. Exact source, CI,
package/container and public-consumer identities will be recorded separately
following publication without moving the release tag.

- [Registry metadata — verify actual returned version](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.4.0)
- [Public Mooncakes ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.4.0.zip)
- [Formal v0.4.0 GitHub Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.4.0)
- [CLI archive installation and runtime requirements](cli-install.md)

The registry metadata endpoint can fall back to another version: require the
actual version field to equal 0.4.0, not just HTTP success. Historical package
0.1.0, tags v0.1.0/v0.2.0 and all existing assets stay unchanged. There is no
separate Mooncakes 0.2.0 or 0.3.0 publication in this release.

## Included scope

0.4.0 includes the unissued 0.3.0 source features: measured explicit 256 KiB/1 MiB
native generation policies (defaults remain 64 KiB), reusable immutable DiffIndex,
and DiffOptions bzip2 levels 1..9 with default 9. It includes CLI limits/show-limits,
header-only inspect/JSON, optional external SHA-256 manifests, verify and checked
patch delivery, guarded Linux compatibility delivery, file-based patch --stream,
and file-only text/JSONL progress and cooperative cancellation. See
[CHANGELOG](../CHANGELOG.md) and [development plan](development-plan.md).

The public library still provides pure diff/apply, explicit Limits and the minimal
read-only header APIs. Native CLI IO is isolated from JS/Wasm-GC library builds.
Registry consumers exercise default diff/apply, reusable index, options and header
prefix APIs on tiny independent data; they do not repeat the library matrix.

## Frozen limits and boundaries

- BSDIFF40 is unchanged and does not authenticate the old file or publisher.
  External manifests bind actual byte sizes/hashes; they require trusted expected
  metadata and are not signatures or secure automatic-update systems.
- patch --stream rejects --manifest; verify and checked patch remain in memory.
  File inputs are not consistent snapshots under concurrent modification.
- Stream workspaces remain format/block bounded, with 4096-byte IO/pulls and
  shared decoded budgets. No whole-process peak-memory or complete bzip2 CPU,
  constant-memory process, strict timeout or immediate-block-interruption promise.
- File-only cancellation handles Linux SIGINT and Windows console Ctrl+C/
  Ctrl+Break. Actual OS tests use child SIGINT and child-console CTRL_BREAK_EVENT;
  Windows keyboard Ctrl+C was not automated. Confirmation before native commit
  admission exits 130 without publication of this operation's output. After
  admission, actual success/error and publication are reported without rollback.
- Linux prefers O_TMPFILE plus /proc; its fallback is limited to the previously
  validated guarded local-ext permission/threat model. It is not all filesystems,
  macOS or network storage. Unknown temporary ownership is retained/reported.
- Output is not replaced, two-file patch/manifest delivery is not a transaction,
  and power-loss durability is not guaranteed.
- Windows/Linux x86_64 archives record actual DLL/loader/library/glibc-symbol
  dependencies. Build-runner success is not a universal/oldest-OS guarantee.
- No generator progress/cancellation, JS asynchronous cancellation, additional
  format, GUI, network update, architecture or tuning parameter was added.

## Release procedure and evidence boundaries

The fixed SDK remains moon 0.1.20261102 (ea07287 2026-11-02),
moonc v0.10.19+bee578715 (2026-11-02), with moonzip 0.3.5 and mooncrypt 0.4.7.
Source/Apache/BSD attribution and existing original/adapted hashes remain intact.

The clean Git export is packaged using the official moon package command and
all member names/bytes audited, including licenses, examples, scripts and data;
SDKs, credentials, caches and oracle binaries are excluded. Candidate and registry
consumption are distinct. Fresh external SDK caches/projects use the exact package
without path/workspace overrides for registry consumption; output bytes are
compared with predefined targets. ZIP-container identities may differ by producer,
so exact package-member identity is also checked against the release source.

Both native release CLI archives are built and smoke-tested after extraction by
the final source SHA's existing CI. New archive checks cover version/help, manifest
roundtrip and stream/JSON completion, with SDK/compiler paths removed. Actual
imports/loader requirements and executable/archive hashes are in build-info.json.
Only those verified CI assets are uploaded; public copies are re-downloaded and
compared without rebuilding or repeating archive execution.

Local verification is limited to the changed release checks, candidate audit,
external consumption and distribution paths. Existing core/CLI/interoperability
checks are reused through the final same-source CI; no local old full matrix,
resource measurement, compression probe or benchmark is rerun.
