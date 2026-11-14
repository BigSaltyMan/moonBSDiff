# Downloadable MoonBSDiff CLI 0.2.0

The distribution target is the formal
[MoonBSDiff CLI v0.2.0 release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.2.0).
The release page and its source-bound CI are the authority for publication and
asset identity; preparing this document alone does not publish anything.
**This is a GitHub CLI release. Mooncakes 0.2.0 has not been published.**
The published Mooncakes 0.1.0 package and v0.1.0 source identity are unchanged.

## Choose, verify, and extract

The release has four assets:

- `moonbsdiff-0.2.0-windows-x86_64.zip`
- `moonbsdiff-0.2.0-linux-x86_64.tar.gz`
- `SHA256SUMS`
- `build-info.json`

Download the archive for your platform, SHA256SUMS and build-info.json from that
same release. Pick a new extraction directory. No administrator access, global
PATH change, MoonBit, Python, or C compiler is required to run the binary.

Linux shell, from the directory containing those downloads:

```sh
sha256sum --ignore-missing --check SHA256SUMS
mkdir moonbsdiff-0.2.0
tar -xzf moonbsdiff-0.2.0-linux-x86_64.tar.gz -C moonbsdiff-0.2.0
./moonbsdiff-0.2.0/moonbsdiff --version
./moonbsdiff-0.2.0/moonbsdiff --help
```

Check that both your archive and build-info.json report OK; `--ignore-missing`
only permits omitting the other platform's archive. Do not accept a changed or
missing selected archive. Windows PowerShell, with all three files downloaded:

```powershell
$asset = 'moonbsdiff-0.2.0-windows-x86_64.zip'
$lines = Get-Content -LiteralPath SHA256SUMS
foreach ($name in @($asset, 'build-info.json')) {
    $entry = @($lines | Where-Object { $_.EndsWith('  ' + $name) })
    if ($entry.Count -ne 1) { throw "Missing/duplicate checksum: $name" }
    $expected = $entry[0].Substring(0, 64)
    if ((Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw "Checksum mismatch: $name" }
}
if (Test-Path -LiteralPath moonbsdiff-0.2.0) { throw 'Extraction directory already exists' }
Expand-Archive -LiteralPath $asset -DestinationPath moonbsdiff-0.2.0
./moonbsdiff-0.2.0/moonbsdiff.exe --version
./moonbsdiff-0.2.0/moonbsdiff.exe --help
```

Version must be exactly `moonbsdiff 0.2.0`. Checksums detect changed content
against a trusted expected checksum; they do not authenticate a publisher if
the archive and checksum are both replaced. Obtain trusted release identities
through a channel appropriate to your use.

## Runtime and filesystem scope

Only Windows AMD64 and Linux x86_64 are distributed. Read the selected platform's
`runtime` entry in build-info.json: it records actual compiler, host/runner image,
PE DLL imports or ELF loader/NEEDED libraries, glibc symbol requirements and
build libc. Linux binaries are dynamically linked, not universal Linux/static
executables. The highest required glibc symbol is an ABI requirement, not proof
of operation on every distribution providing it. Windows system DLL/UCRT
requirements are not a promise of every Windows version. CI rejects an
unhandled VCRUNTIME/MSVCP/CONCRT dependency rather than silently shipping it
without a runtime distribution policy. No system runtime DLLs are bundled.

Each platform archive is executed on its actual build runner after extraction.
This establishes that environment, not a separately tested oldest supported OS.
The final build-info.json records those environments and actual requirements.
No macOS, ARM, network-filesystem, or universal platform support is added.

Linux output prefers O_TMPFILE and `/proc`; explicit pre-write capability
absence can select the guarded local-ext compatibility path. That path needs
trusted-owner/protected parent permissions, exact private-object modes and
hard-link publication. Other fallback filesystems fail closed. ext4 without
`/proc` was actually exercised; this is not support for every Linux filesystem.
See [Linux delivery design](linux-delivery.md).

## Use

Use the extracted executable's full/relative path in place of `moonbsdiff`:

```sh
moonbsdiff diff --manifest update.json old.bin new.bin update.patch
moonbsdiff inspect --json update.patch
moonbsdiff verify --manifest update.json old.bin update.patch
moonbsdiff patch --manifest update.json old.bin update.patch restored.bin
moonbsdiff diff --show-limits
moonbsdiff patch --max-patch-bytes 256KiB --show-limits
```

These commands cover effective limit configuration, header-only inspect,
external SHA-256 manifests and actual verification/checked restoration. Hash
manifests do not prove publisher identity. Outputs are not overwritten. Patch
and manifest delivery is not a cross-file transaction; partial completion is
reported without deleting a delivered patch. Default sizes/work quotas remain
unchanged. No whole-process peak-memory, full bzip2 CPU, wall-clock or durability
guarantee is introduced. See [CLI contracts](cli.md) and [manifest policy](manifest.md).

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

An independent CI collection job requires exactly the two platform archives and
records, checks their source SHA equals the workflow checkout, verifies hashes
and embedded provenance, and emits the four public assets. build-info.json is
external so archive hashes are not self-referential. Ordinary pushes only build
and verify; they never create tags or releases. Formal publication reuses those
exact successful-CI bytes. Fixed archive metadata does not imply a bit-level
reproducibility claim for compiler output.
