# Native command line and file delivery

## Build and commands

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

The executable reports `moonbsdiff 0.1.0` from generated module metadata.
CI checks generated source and actual --version against moon.mod to catch drift.
Our order is **patch OLD PATCH OUTPUT**, different from upstream
**bspatch OLD NEW PATCH**. Exactly three file arguments are required. Exit codes:
0 success, 2 invalid command/arguments, 1 operation failure. Help/version use stdout;
operation errors use stderr, with operation, relevant paths and core kind/stage/
field/value/limit metadata where available. Successful diff/patch are silent.
No overwrite switch, stdin protocol, network update or directory synchronization
is provided.

## Dependencies and native isolation

No new Mooncakes IO dependency is introduced. The pinned toolchain core/env and
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

`diff` uses Limits::for_diff unchanged. `patch` starts from Limits::for_apply and
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

Linux opens the target directory and creates an **unnamed fresh inode** there
with O_TMPFILE, mode 0600. It has no temporary pathname that could collide or be
replaced. O_EXCL is deliberately not combined with O_TMPFILE: Linux gives that
combination a different meaning that prohibits later linking. An O_PATH reference
retains the inode through /proc/self/fd while the writing descriptor is completely
written and closed. linkat with AT_SYMLINK_FOLLOW on that reference creates the
final name; the kernel refuses every existing destination. Cleanup closes the
anonymous references, so no path-based deletion race exists. The opened directory
anchors the destination. This requires O_TMPFILE filesystem support and /proc;
unsupported filesystems fail explicitly, with **no unsafe rename fallback**.
The locally verified Linux output filesystem is /tmp on WSL ext4, not a claim
that all mounted/network/Windows-backed filesystems implement these operations.

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
