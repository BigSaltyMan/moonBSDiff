# Downloadable MoonBSDiff CLI

See [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases) for
published archives. Starting with `v0.6.0`, releases ship 6 assets across 4
CI-built native targets (4 archives, `SHA256SUMS`, and `build-info.json`, with
`<VERSION>` matching `moon.mod`); earlier releases `v0.5.0` through `v0.5.4`
shipped 4 assets (Windows and Linux `x86_64`, `SHA256SUMS`, `build-info.json`).
See the [0.6.0 release record](release-0.6.0.md),
[0.5.4 release record](release-0.5.4.md), [0.5.0 release record](release-0.5.0.md),
and [0.4.0 record](release-0.4.0.md) for published package and CLI identities.

- `moonbsdiff-<VERSION>-windows-x86_64.zip`
- `moonbsdiff-<VERSION>-linux-x86_64.tar.gz`
- `moonbsdiff-<VERSION>-linux-arm64.tar.gz`
- `moonbsdiff-<VERSION>-macos-arm64.tar.gz`
- `SHA256SUMS`
- `build-info.json`

Intel macOS (`macos-x86_64`) is not built in CI because upstream MoonBit
`0.10.19` does not publish `darwin-x86_64` native toolchains.

## Choose, verify, and extract

Download the archive for your platform, `SHA256SUMS`, and `build-info.json` from
the same release. Pick a new extraction directory. No administrator access,
global `PATH` change, MoonBit, Python, or C compiler is required to run the
binary.

Linux shell (`x86_64` or `arm64`, substituting the downloaded `<VERSION>` and `<ARCH>`):

```sh
sha256sum --ignore-missing --check SHA256SUMS
mkdir moonbsdiff-<VERSION>
tar -xzf moonbsdiff-<VERSION>-linux-<ARCH>.tar.gz -C moonbsdiff-<VERSION>
./moonbsdiff-<VERSION>/moonbsdiff --version
./moonbsdiff-<VERSION>/moonbsdiff --help
```

Check that both your archive and `build-info.json` report `OK`; `--ignore-missing`
only permits omitting the other platforms' archives. Do not accept a changed or
missing selected archive.

macOS shell (`arm64`, substituting the downloaded `<VERSION>`):

```sh
grep -E '  (moonbsdiff-<VERSION>-macos-arm64\.tar\.gz|build-info\.json)$' SHA256SUMS | shasum -a 256 -c -
mkdir moonbsdiff-<VERSION>
tar -xzf moonbsdiff-<VERSION>-macos-arm64.tar.gz -C moonbsdiff-<VERSION>
./moonbsdiff-<VERSION>/moonbsdiff --version
./moonbsdiff-<VERSION>/moonbsdiff --help
```

Check that both your macOS archive and `build-info.json` report `OK`.

Windows PowerShell (`x86_64`, with the downloaded `<VERSION>` substituted):

```powershell
$version = '<VERSION>'
$asset = "moonbsdiff-$version-windows-x86_64.zip"
$lines = Get-Content -LiteralPath SHA256SUMS
foreach ($name in @($asset, 'build-info.json')) {
    $entry = @($lines | Where-Object { $_.EndsWith('  ' + $name) })
    if ($entry.Count -ne 1) { throw "Missing/duplicate checksum: $name" }
    $expected = $entry[0].Substring(0, 64)
    if ((Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw "Checksum mismatch: $name" }
}
if (Test-Path -LiteralPath "moonbsdiff-$version") { throw 'Extraction directory already exists' }
Expand-Archive -LiteralPath $asset -DestinationPath "moonbsdiff-$version"
& "./moonbsdiff-$version/moonbsdiff.exe" --version
& "./moonbsdiff-$version/moonbsdiff.exe" --help
```

Version output must match `moonbsdiff <VERSION>`. Checksums detect changed
content against a trusted expected checksum; they do not authenticate a
publisher if both the archive and `SHA256SUMS` are replaced. Obtain trusted
release identities through a channel appropriate to your use.

## Runtime and filesystem scope

Four CI-built native targets are shipped starting with `0.6.0`:
`windows-x86_64`, `linux-x86_64`, `linux-arm64`, and `macos-arm64` (earlier
`0.5.x` archives covered `windows-x86_64` and `linux-x86_64` only; Intel macOS
`macos-x86_64` is not built in CI because upstream MoonBit `0.10.19` does not
publish `darwin-x86_64` native toolchains). Read the selected platform's
`runtime` entry in `build-info.json`: it records actual compiler, host/runner
image, PE DLL imports, ELF loader/`NEEDED` libraries and glibc symbols, or
Mach-O dylib imports and macOS build version.

- **Linux (`x86_64` and `arm64`)**: dynamically linked ELF64 executables (`x86_64`
  or `AArch64`) with no `RPATH`/`RUNPATH` and a loader under `/lib*`, not
  universal static executables. The highest required glibc symbol is an ABI
  requirement, not proof of operation on every distribution providing it. Output
  delivery prefers `O_TMPFILE` and `/proc`; explicit pre-write capability absence
  can select the guarded local-ext compatibility path (`0700` private directory,
  `0600` payload, non-replacing `linkat`), requiring trusted-owner/protected
  parent permissions. Other fallback filesystems fail closed. See
  [Linux delivery design](linux-delivery.md).
- **macOS (`arm64`)**: single-architecture (`Non-fat`) 64-bit Mach-O
  `MH_EXECUTE` binaries with no `LC_RPATH`, dynamically linked solely against
  `/usr/lib/` and `/System/Library/` system libraries (validated via `lipo -info`,
  `otool -L`, and `otool -l` during packaging). No universal minimum macOS
  version is claimed. Safe non-overwriting delivery requires protected parent
  permissions (`euid` or `root` owner, sticky bit if group/world-writable),
  generates names via `arc4random_buf`, creates a `0700` private directory and
  exclusive `0600` payload, and commits with non-replacing `linkat`. Streaming
  input copies open `/private/tmp` (falling back to `$TMPDIR` if `/private/tmp`
  cannot be opened), check protected/sticky directory permissions, and unlink each
  exclusive `0600` scratch file before writing. Output pair preflight checks
  `fpathconf(_PC_CASE_SENSITIVE)` to guard against APFS/HFS+ case-insensitive
  path aliases, and CLI argument handling checks strict UTF-8 via `_NSGetArgc`
  and `_NSGetArgv`.
- **Windows (`x86_64`)**: PE32+ x86_64 executables using system DLLs/UCRT;
  packaging rejects unhandled `VCRUNTIME`/`MSVCP`/`CONCRT` dependencies rather
  than bundling runtime DLLs. Delivery uses `CREATE_NEW` and
  `SetFileInformationByHandle(FileRenameInfo, ReplaceIfExists=FALSE)`, CSPRNG
  uses `BCryptGenRandom`, and arguments are parsed as UTF-16 via
  `GetCommandLineW`/`CommandLineToArgvW`.

Each platform archive is executed on its actual build runner after extraction.
This establishes that environment, not a separately tested oldest supported OS.
No network-filesystem or universal platform support is added.

## Use

Use the extracted executable's full/relative path in place of `moonbsdiff`:

```sh
moonbsdiff diff --manifest update.json old.bin new.bin update.patch
moonbsdiff inspect --json update.patch
moonbsdiff verify --manifest update.json old.bin update.patch
moonbsdiff patch --manifest update.json old.bin update.patch restored.bin
moonbsdiff diff --show-limits
moonbsdiff patch --max-patch-bytes 256KiB --show-limits

# Optional detached Ed25519 manifest signing and verification (unreleased):
moonbsdiff manifest keygen publisher.key publisher.pub
moonbsdiff manifest sign --private-key publisher.key update.json update.sig
moonbsdiff manifest verify-sig --public-key publisher.pub --signature update.sig update.json
moonbsdiff verify --stream --manifest update.json --public-key publisher.pub --signature update.sig old.bin update.patch
moonbsdiff patch --stream --manifest update.json --public-key publisher.pub --signature update.sig old.bin update.patch verified.bin
```

These commands cover effective limit configuration, header-only inspect,
external SHA-256 manifests, detached Ed25519 manifest signatures, and actual
verification/checked restoration. Unsigned SHA-256 manifests check content
identity only and do not prove publisher identity; pin a trusted Ed25519
`PUBLIC_KEY_FILE` out-of-band and pass `--public-key` + `--signature` when
publisher authentication is required. Outputs are not overwritten. Patch and
manifest delivery is not a cross-file transaction; partial completion is
reported without deleting a delivered patch. Default sizes/work quotas remain
unchanged. No whole-process peak-memory, full bzip2 CPU, wall-clock or durability
guarantee is introduced. See [CLI contracts](cli.md) and [manifest policy](manifest.md).

To verify the downloaded executable against the fixed update scenario, use Python
3.10+ for the demo/build/packaging scripts (Python 3.11+ is required for the CLI
`unittest` test suite, which uses `contextlib.chdir`) together with the scripts
and fixtures from a clean checkout or source archive of the matching tag. From
that source root, point the demo at the extracted CLI:

```sh
python scripts/run_update_demo.py --cli /path/to/extracted/moonbsdiff
```

Use the path to `moonbsdiff.exe` on Windows. On the current tree, the demo
verifies the fast-path `2048`, `359` (`204 + 155`), and `0`-byte download
choices and compares the delivered 2048 bytes with an independent target.
Published `v0.5.0`–`v0.5.4` binaries predate the common prefix/suffix fast path
and generate a `164`-byte `v2-to-v3.patch` (`368` bytes total), so verify them
with the matching tag's `scripts/run_update_demo.py` rather than the current
tree's script. See the [project acceptance page](update-demo.md) for the
expected hash and demo output.

## Build/provenance procedure

CI uses moon `0.1.20261102 (ea07287 2026-11-02)`, moonc
`v0.10.19+bee578715`, the existing platform-native compiler environments, and
`python scripts/build_cli.py --release`. From a clean tracked source SHA:

```sh
python scripts/package_cli.py
```

The entrypoint builds the real native release artifact, inspects its binary
imports, assembles a minimal product archive and unpacks it into a fresh
directory. It executes help/version and one small manifest/checked-patch
roundtrip, verifies all bytes and independent hashes, and records archive and
executable identities. Failures are fatal. There is no historical test-matrix
invocation in this entrypoint. The output `_build/cli-dist` must not already
exist; choose `--output` with a fresh path for another run.

Per-platform files retain the exact project/BSDiff/Apache license materials,
core NOTICE and pinned SDK credits. `docs/cli-sdk-credits.txt` copies CREDITS.md (only trailing whitespace normalized)
from the verified 0.10.19+bee578715 Windows SDK. It also mentions
optional SDK tools; those tools and the SDK itself are not in the CLI archive.
No C oracle program or Python implementation is bundled.

An independent CI collection job (`scripts/collect_cli_release.py`) requires all
four CI-built platform archives (`windows-x86_64`, `linux-x86_64`, `linux-arm64`,
`macos-arm64`) and `build-info-<system>-<arch>.json` records, checks their
source SHA equals the workflow checkout, verifies hashes and embedded
provenance, and emits the six public assets (the four archives,
`build-info.json`, and `SHA256SUMS`; `0.5.0`–`0.5.4` releases emitted the
two-platform / four-asset layout; Intel macOS `macos-x86_64` is excluded because
upstream MoonBit `0.10.19` does not publish `darwin-x86_64` native toolchains). `build-info.json` is external so archive
hashes are not self-referential. Ordinary pushes only build and verify; they
never create tags or releases. Formal publication reuses those exact
successful-CI bytes. Fixed archive metadata does not imply a bit-level
reproducibility claim for compiler output.
