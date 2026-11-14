# Native command line and file delivery

## Download, build and commands

[Prebuilt CLI 0.2.0 download, checksums and runtime requirements](cli-install.md)
are separate from Mooncakes: 0.2.0 is not published there. Source builds below
require the SDK/compiler; running the prebuilt CLI does not.

Supported and actually exercised: Windows 11 AMD64 and Ubuntu 24.04/WSL2 Linux
x86_64, with moon 0.1.20261102 (ea07287), moonc v0.10.19+bee578715,
moonrun 0.1.20261102 (2026-11-02 builds). Native only; no macOS CLI support is
claimed. The root library remains pure MoonBit and still checks on JS/Wasm-GC.

From the repository root with that isolated toolchain on PATH, Python 3 and a
native C compiler available:

```sh
python scripts/build_cli.py
python scripts/build_cli.py --check-version
```

On Windows initialize the MSVC developer environment first (the verified local
script is `C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat`).
The script generates `cmd/main/version.mbt` from the module's `version` field,
builds `cmd/main` for native, and copies the actual artifact to:

- Windows: `_build/bin/windows/moonbsdiff.exe`
- Linux: `_build/bin/linux/moonbsdiff`

The toolchain names its intermediate artifact `main.exe` on both hosts; the
build script handles this. Caches are separated as `_build/cli-windows` and
`_build/cli-linux`. `--release` selects native release; the retained file tests
use the default debug build. No Python/C reference program is called at runtime;
Python is used for building, generated-version checking and testing only.

PowerShell examples (quote paths containing spaces or Chinese characters):

```powershell
& .\_build\bin\windows\moonbsdiff.exe --help
& .\_build\bin\windows\moonbsdiff.exe --version
& .\_build\bin\windows\moonbsdiff.exe diff ".\old file.bin" ".\new file.bin" ".\update.patch"
& .\_build\bin\windows\moonbsdiff.exe patch ".\old file.bin" ".\update.patch" ".\restored file.bin"
```

Linux equivalents:

```sh
./_build/bin/linux/moonbsdiff --help
./_build/bin/linux/moonbsdiff --version
./_build/bin/linux/moonbsdiff diff 'old file.bin' 'new file.bin' 'update.patch'
./_build/bin/linux/moonbsdiff patch 'old file.bin' 'update.patch' 'restored file.bin'
```

The executable reports `moonbsdiff 0.2.0` from generated module metadata.
CI checks generated source and actual --version against moon.mod to catch drift.
Our order is **patch OLD PATCH OUTPUT**, different from upstream
**bspatch OLD NEW PATCH**. Diff/patch operations require exactly three file arguments; inspect takes one, and --show-limits takes none. Exit codes:
0 success, 2 invalid command/arguments/configuration, 1 operation failure. Help/version use stdout;
operation errors use stderr, with operation, relevant paths and core kind/stage/
field/value/limit metadata where available. Successful diff/patch are silent.
No overwrite switch, stdin protocol, network update or directory synchronization
is provided.

## Patch inspection (CLI 0.2.0)

```sh
./_build/bin/linux/moonbsdiff inspect testdata/upstream/replace/patch.bin
./_build/bin/linux/moonbsdiff inspect --json testdata/upstream/replace/patch.bin
./_build/bin/linux/moonbsdiff inspect --max-patch-bytes 256KiB testdata/upstream/replace/patch.bin
```

Only --json and --max-patch-bytes are supported for inspect, with the same
options-before-path and -- rules as Commit 17. The default read cap is 128 KiB;
byte parsing/ranges are unchanged. The single file is bounded before parsing.
Text/JSON go to stdout only on success; errors use stderr and exit 2 (arguments)
or 1 (read/format). No output file or temporary delivery file is created.
Inspection validates only the header and physical ranges, not streams/CRC,
controls, restoration or identity. Declared output sizes are reported without
allocation or apply policy. [Inspection schema and real outputs](inspect.md)
describe decimal-string byte fields, lossless Int64 and JSON escaping. This is
not --deep, manifest validation or a full patch-verification command. The feature
is not in published 0.1.0; generated CLI version remains module metadata.

## External manifest output (CLI 0.2.0)

```sh
./_build/bin/linux/moonbsdiff diff --manifest update.json old.bin new.bin update.patch
```

Diff accepts --manifest PATH as an output; patch/verify accept it as input, once, before operands. It is incompatible
with --show-limits. A leading-hyphen manifest value uses ./-name; positional --
rules are unchanged. The optional JSON binds actual old/new/patch buffers with
full lowercase SHA-256 and decimal-string sizes. BSDIFF40 bytes are unchanged.
The tool version is actual generated metadata, not a promised next release.

Both outputs are prechecked for existing/input targets and parent-identity/name
aliases. All data is prepared before patch then manifest are delivered by the
existing no-overwrite mechanism. This is not a two-file atomic transaction:
manifest failure exits 1 with patch-delivered/manifest-incomplete diagnostics,
keeps the patch and does not roll back by deleting caller paths. Check existing
outputs before retrying. Success remains silent. [Schema, real manifest, hash
source, platform details and partial failure](manifest.md) define the contract.
SHA-256 does not authenticate the publisher; a manifest replaced together with
its patch cannot supply authenticity. Bounded verify/checked restoration is described below.

## Verify and checked patch (CLI 0.2.0)

```sh
./_build/bin/linux/moonbsdiff verify --manifest testdata/manifest/update.json testdata/manifest/old.bin testdata/manifest/update.patch
./_build/bin/linux/moonbsdiff patch --manifest update.json old.bin update.patch restored.bin
```

Verify requires a manifest and exactly OLD/PATCH operands; it actually performs
bounded in-memory apply, checks restored content and prints one success line,
without a final output file. Patch's optional manifest uses that same pipeline
and delivers only after all identities match. Plain patch is unchanged and does
not reliably identify the old file. Inspect remains header-only.

Manifest input is capped at 16 KiB with a depth-8 strict UTF-8/JSON parser; all
duplicate (including escaped-equivalent) and unknown keys are rejected. Schema 1,
BSDIFF40, required objects/fields, exact decimal-string sizes (zero allowed for
content), lowercase SHA-256 and producer string types are checked. Producer
metadata confers no trust. Effective old/patch/new/output caps are checked before
input reads or restored allocation; hashes bind the same Bytes passed to apply.
Output aliases of old, patch or manifest and existing targets are refused by the
unchanged native check/delivery. All verification failures leave inputs and final
output untouched; delivery failure retains its previously documented boundary.

Verify accepts meaningful patch limit overrides, not sorting/matching, --json or
--show-limits. Existing prefix-options/--/duplicates rules apply. Parameter/config
errors exit 2; read/schema/identity/apply/restoration/delivery errors exit 1 on
stderr, with empty stdout. Success exits 0 (checked patch is silent).
[Full input policy, stages and test evidence](manifest.md#bounded-consumption-and-checked-restoration-commit-20)
distinguish this content check from publisher authentication. There is no signature,
network fetch, automatic update or streaming restoration.

## Dependencies and native isolation

No new Mooncakes IO dependency is introduced. Manifest hashing pins the already-resolved mooncrypt 0.4.7 as a direct CLI hashing dependency (Apache-2.0). The pinned toolchain core/env and
core/encoding/utf8 provide exit/Unix arguments and string encoding. The inspected
core/async/fs API includes binary files, create modes and `rename(replace?)`;
we use a small synchronous native C adapter to make descriptor identity, checked
close, anonymous temp lifetime and no-replace commit explicit in one auditable
place, without importing the experimental async runtime into the root package.

The adapter is original BSD-2-Clause code under `cmd/main/native_io.c`; no third-
party source was copied. Its dependencies are the existing MoonBit native ABI,
Windows system APIs or Linux libc/kernel interfaces. Core's Apache-2.0 notice
remains part of the toolchain; moonzip 0.3.5 and all core library dependencies are
unchanged. `supported_targets = "-all+native"` isolates cmd/main. The root public
.mbti and core algorithms are unchanged. The CLI exposes no library/debug API.

Windows arguments are parsed directly with GetCommandLineW/CommandLineToArgvW
and copied as UTF-16 MoonBit strings, avoiding the runtime's documented ANSI
fallback under MinGW. All file paths use UTF-8 -> UTF-16 conversion and wide
Windows APIs. Linux paths must be representable as Unicode/UTF-8; arbitrary
invalid-byte filenames are not part of the tested contract. Chinese and space
paths were actually exercised on both platforms.

## Limits and bounded reads

Without overrides, `diff` uses Limits::for_diff unchanged. `patch` starts from Limits::for_apply and
changes **only max_patch_bytes to 131072**, taking the value from for_diff.
This accepts default generator output without changing either measured library
factory or relaxing unrelated application limits.

| CLI | Old | New/restored | Patch | Expanded bytes | Instructions |
| --- | ---: | ---: | ---: | ---: | ---: |
| diff | 65536 | 65536 | 131072 | 262144 | 4096 |
| patch | 1048576 | 1048576 | 131072 | 2097152 | 16384 |

Sort/matching-generation quotas for diff remain 8388608 each. Generation can
still fail below size caps on another independent quota. A real 65536-byte
independent LCG old/new pair produced a **66279-byte patch** and restored exactly
on both platforms. Its sizes, hashes and seeds are retained in the file-test
record. Thus the >64 KiB path is exercised, not inferred from configuration.

The reader opens regular binary files, obtains size using fstat/GetFileSizeEx,
and rejects a known over-limit file before a whole-file allocation or read.
Stat/open/regular-file errors fail closed. Each bounded read requests at most
4096 bytes, or the remaining allowance plus one witness byte. The cumulative
size is checked before reallocating/appending to the result. Capacity growth
uses subtraction/division to remain <= the Int-sized cap; a growing file or
zero/uninformative size cannot bypass the running check. A stat/read/close error
returns no input value to the CLI. The core diff/apply still perform their own
checks. This is in-memory processing, not a streaming core algorithm.

Concurrent file mutation is not a consistent snapshot guarantee. BSDIFF40 does
not contain old-file identity hashes; callers must verify intended old and new
hashes externally. Input buffers/files are never written by product operations.

## CLI overrides (CLI 0.2.0)

These CLI additions are **not included in published 0.1.0**. The
module-generated version string is 0.2.0 for this GitHub CLI release;
use the checkout SHA to identify unreleased CLI behavior. No library defaults,
public signatures, dependencies or native file-delivery mechanisms changed.

```text
moonbsdiff diff [OPTIONS] OLD NEW PATCH
moonbsdiff patch [OPTIONS] OLD PATCH OUTPUT
moonbsdiff diff [OPTIONS] --show-limits
moonbsdiff patch [OPTIONS] --show-limits
```

All options precede all three paths. Each option takes a separate value token;
`--option=value` is rejected. `--` ends option parsing; paths beginning with `-`
require this separator, e.g. `moonbsdiff diff -- -old -new -patch`. Unknown,
repeated (even identical) or inapplicable options, missing values, misplaced
options and wrong path counts exit 2 before file IO. No config file/environment
overrides or implicit unlimited setting exists.

| Option | Limits field | Applies to | Meaning |
| --- | --- | --- | --- |
| --max-old-bytes | max_old_bytes | diff, patch | Old input read and core input cap |
| --max-new-bytes | max_new_bytes | diff, patch | New file read/target size for diff; declared restored size for patch |
| --max-output-bytes | max_output_bytes | diff, patch | Target buffer/size cap, independent of max_new_bytes; not compressed patch output |
| --max-patch-bytes | max_patch_bytes | diff, patch | Generated final patch cap for diff; patch file read/core cap for patch |
| --max-expanded-bytes | max_decompressed_bytes | diff, patch | Raw control+diff+extra aggregate for diff; cumulative decoded aggregate for patch |
| --max-controls | max_control_instructions | diff, patch | Control triple count |
| --max-sort-work | max_sort_work | diff only | Cumulative suffix-index work units |
| --max-match-work | max_match_work | diff only | Cumulative matching and generation work units |

Byte values are ASCII positive decimals, optionally followed immediately by
case-sensitive B, KiB (1024) or MiB (1048576), e.g. 256KiB. No signs, whitespace,
decimal fractions, separators or other units are accepted. Control/work values
are positive ASCII decimal integers with **no suffix**. Leading zeros are allowed
but an all-zero value is rejected. Decimal and unit multiplication are checked
against Int64 maximum before arithmetic; Limits::validate then checks the four
individual buffer caps in 1..2147483647. Expanded aggregate, controls and work
are in 1..9223372036854775807. Zero/negative values never mean unlimited.

`--show-limits` takes no value and cannot be combined with file parameters. It
prints the operation and effective field values after defaults plus overrides,
with actual byte counts and units, exits 0, and performs no input/output/core
operation. Invalid configuration exits 2. Patch labels sorting/matching as unused
rather than exposing the apply factory's placeholder 1 as an effective budget.
For example, from a built source checkout:

```sh
./_build/bin/linux/moonbsdiff diff --max-old-bytes 256KiB --show-limits
./_build/bin/linux/moonbsdiff patch --show-limits
```

The first displays max_old_bytes: 262144 bytes, while max_new_bytes and
max_output_bytes remain 65536 bytes and sort/match remain 8388608 work units.
An explicit small file operation (5-byte old and 6-byte new in the directed test):

```sh
./_build/bin/linux/moonbsdiff diff --max-old-bytes 5B --max-new-bytes 6 --max-output-bytes 6B --max-patch-bytes 1KiB --max-expanded-bytes 1KiB --max-controls 4 --max-sort-work 4096 --max-match-work 65536 old.bin new.bin update.patch
```

The parser finishes and validates the complete configuration before the early
output check or any read. The same validated Limits supplies native read caps
(old, new or patch), is narrowed only within the proven Int range, and is passed
to public diff/apply. Read failures name the field and effective byte cap; core
failures retain kind/stage/field/value/limit. Output/delivery logic is unchanged.
Raising one cap never raises another; for example raising new alone can still
fail the output or work quota. Accepting a numeric limit does not establish
performance/peak-memory acceptance at that size. Linux delivery follows the
primary/guarded compatibility policy below; no-overwrite requirements still apply.

Directed verification: `python scripts/test_cli_limits.py --exe PATH_TO_CLI`.
This reuses existing file/error helpers but runs only five new CLI contracts
(38 subprocess calls): display/defaults/units, default and explicit roundtrips,
reader/core enforcement and failure recovery, 19 invalid-argument table rows,
and `--` paths. Windows and Linux passed with no skips. Target/output-buffer size limits retain
the existing Header preflight error stage. Historical 31-file/9-private suites,
142 library tests, interoperability and resource measurements were not rerun
locally; existing CI retains them and adds this collection after its CLI build.

## Identity and no-overwrite delivery

An early output check rejects existing files, directories and links. Identity
comparison uses Windows volume/file-index information or POSIX st_dev/st_ino,
following applicable input/output links, rather than comparing path spelling.
Relative/absolute normalization, hard links and directory aliases are tested.
Dangling output links are also rejected by the final commit operation even if a
preliminary metadata query cannot follow them. The early check is diagnostic;
the actual commit independently forbids replacement under a target-creation race.

Windows creates a named temporary file **in the target directory** using CREATE_NEW.
A collision retries another name (at most 128 attempts); no colliding file is
removed. The file denies other opens for write/delete. A duplicated handle with
DELETE/READ_ATTRIBUTES only retains identity while the writing handle is fully
written and successfully closed. SetFileInformationByHandle(FileRenameInfo) then
renames that held file with ReplaceIfExists=FALSE. A target appearing meanwhile
causes failure. Failure cleanup marks the owned temporary file for deletion by
that same held handle; it never deletes a supplied/colliding path.

The preferred Linux path opens the target directory and creates an **unnamed fresh inode** there
with O_TMPFILE, mode 0600. It has no temporary pathname that could collide or be
replaced. O_EXCL is deliberately not combined with O_TMPFILE: Linux gives that
combination a different meaning that prohibits later linking. An O_PATH reference
retains the inode through /proc/self/fd while the writing descriptor is completely
written and closed. linkat with AT_SYMLINK_FOLLOW on that reference creates the
final name; the kernel refuses every existing destination. Cleanup closes the
anonymous references, so no path-based deletion race exists. The opened directory
anchors the destination. This primary route requires O_TMPFILE support and /proc.
The new guarded compatibility route below can work without those facilities;
unsupported conditions still fail explicitly, with **no unsafe rename fallback**.
The locally verified Linux output filesystem is /tmp on WSL ext4, not a claim
that all mounted/network/Windows-backed filesystems implement these operations.

Commit 21 (CLI 0.2.0) adds a Linux compatibility route only on explicit
anonymous/proc capability errors, before writing. It requires local ext filesystem
magic 0xef53, a trusted-owner/protected parent, verified 0700 private directory and
0600 exclusively created payload. All operations stay descriptor-anchored; final
linkat never replaces a target. Cleanup depends on those permission invariants,
not an assumed atomic inode-check/unlink. Identity uncertainty retains objects
and reports failure, and an error after linking explicitly says output delivered.
No user path is removed to roll back. Malicious same-UID/root manipulation is
outside this narrower route's model; no broad hostile-parent guarantee follows.
[Full route/error policy and real no-proc evidence](linux-delivery.md) distinguish
forced tests from an actual unprivileged isolated run. No Windows delivery code,
core API/default or dependency changed; DrvFS/9p and other fallback filesystems
remain unsupported. The primary route remains preferred when available.

Both paths loop on short writes and treat zero progress, write and writer-close
errors as failure before commit. Only files created by the current operation
are cleaned up. If a final identity/directory close fails after commit, the CLI
reports failure but may leave the complete newly created result; it does not
attempt a risky path-based rollback. No prior output is replaced. File/dir fsync,
power-loss durability and all possible filesystem/hostile-parent behaviors are
not promised. Existing-output safety comes from kernel no-replace semantics,
not from a check-then-overwriting-rename sequence.

## Tests and reproduction

```sh
python scripts/test_cli.py --exe _build/bin/linux/moonbsdiff
# Windows: python scripts/test_cli.py --exe _build/bin/windows/moonbsdiff.exe
```

The script requires a real executable and launches subprocesses, checking exact
exit codes, stdout/stderr, complete file bytes and unchanged prior files. An
empty suite is a failure. It also runs exactly nine native private IO contracts
through `moon test cmd/main --target native --deny-warn` in the platform cache.
The private entry is declared only in the white-box test; no product flag or
environment variable enables faults.

31 file tests cover command errors; complete, identical, empty and binary
roundtrips; Unicode/space/relative/absolute paths; >64 KiB patch compatibility;
old/new/patch input caps; missing/nonregular/unreadable inputs; actual permission
refusal; invalid header and independently checked CRC corruption; existing
outputs, input aliases, hard/symbolic links, dangling links and missing/unwritable
parents. Failure checks preserve input/existing output bytes and reject leaked
named temporaries. The CRC case flips a checksum byte, not a possible padding
bit, and independent Python bz2 confirms the mutation is invalid.

Nine additional private contracts use real files and deterministic fault points:
Windows actual name collision (Linux: anonymous inode ignores old matching names),
target creation immediately before commit, actual input append after stat,
partial write then injected failure, simulated writer-close error after real close,
injected delivery error, simulated input-close error, uninformative size with
running-cap rejection, and repeated short writes. They verify error paths,
unchanged prior files, preserved racing output, no partial committed output, and
only the expected directory entries. Synthetic errors do not replace the real
file/permission tests; actual close failures are not claimed to have been forced
from the operating system.

Local results and sanitized artifact/source identity are in
[testdata/cli/native-results.json](../testdata/cli/native-results.json): Windows
31 scheduled, 29 passed, 2 skipped (symlink privilege WinError 1314), 50 CLI
subprocesses and 9/9 private contracts. Windows hard links, directory junctions,
exclusive read sharing and a temporary directory deny ACL were exercised; the ACL
was restored. Linux 31/31, no skips, 52 CLI subprocesses and 9/9 private contracts.
The Linux test user was non-root uid 1000; chmod refusal was verified by a direct
probe before counting permission cases. Two Windows symlink skips are not passes.

Native Windows debug build used MSVC 19.44 tooling; Linux used GCC 13.3.0 and
Python 3.12.3, Windows Python 3.14.6. The Linux isolated archive was obtained from
the official versioned source via Windows after a WSL connection reset:

```text
https://cli.moonbitlang.com/binaries/0.10.19%2Bbee578715/moonbit-linux-x86_64.tar.gz
SHA256 dd1d6d793c9675405ef32b39bce66d40041e2052a9c3f2f403e0a9da98bd94fd
https://cli.moonbitlang.com/cores/core-0.10.19%2Bbee578715.tar.gz
SHA256 b5b33afc759b8ae332346f357f42235d4c8d54afd91bb891b22ead3d746fa74f
```

The core was bundled using `moon bundle --all` inside the isolated core directory;
existing registry metadata was reused locally. Global toolchains were untouched.
CI uses the existing SHA-pinned setup action, exact version and moon update on
fresh runners. The original library CI remains; Linux and Windows native CLI jobs
actually build/test these commands. Final remote results are reported separately
for the final commit; they are not prefilled as success here.

No root algorithm/compression change, oracle rebuild, historical patch generation,
full local random interoperability matrix, resource measurement or historical
large compression sample was repeated for this IO-only step. The existing remote
library pipeline may run its normal suite. Product distribution, full platform
policy, examples and publication remain Commit 13-16.
