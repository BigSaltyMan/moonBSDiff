# MoonBSDiff

MoonBSDiff is a MoonBit reference port of BSDiff 4.3 for binary diffs and patches. The current stage implements structured errors, `Limits::validate`, internal BSDIFF40 integer/envelope parsing, and a private bounded bzip2 adapter. Public diff and apply APIs now generate and restore strict BSDIFF40 patches. A native Windows/Linux CLI is available; see [CLI build and file contracts](docs/cli.md). Compression uses moonzip 0.3.5 at level 9; strict bounded decoding uses its attributed, adapted sources under `internal/bzip2/`.

The `Limits` fields for old, new, patch and output buffer sizes are byte counts in 1..2147483647, bounded for Int indexing. `max_decompressed_bytes` is an aggregate byte count, `max_control_instructions` counts instructions, and `max_sort_work` / `max_match_work` count algorithm-defined work units; each is a positive Int64. Sorting visits accumulate across index rounds; matching/generation visits accumulate across scan, raw encoding, compression-wrapper copies and final assembly; see [generation resources](docs/generation-resources.md). Limits::for_apply() supplies conservative application defaults: old/new/output 1 MiB each, patch 64 KiB, total decompression 2 MiB and 16384 instructions. Sorting/matching fields are unused positive placeholders, not generation defaults; use the separate measured Limits::for_diff() policy for generation. Validation means only that a configuration is legal, not that a complete patch operation has runtime resource protection. The private decoder now enforces per-call and shared decompression budgets. No cross-field relationships are imposed.

Errors provide a kind, stage, and optional block, offset, field, value and limit. Missing details are `None`. See the generated interface for exact types.

The verified local baseline is moon 0.1.20261102 and moonc 0.10.19+bee578715; the PATH default 0.10.13 is older and was not used for final validation. `moon.mod` declares moonzip 0.3.5; `moon tree` reports the resolved transitive versions in [sources](docs/upstream.md). No version lockfile was generated: `.mooncakes/.moon-lock` is an empty synchronization file, not a dependency lock. The resolved tree is a snapshot and should be rechecked; the transitive versions are not reproducibly locked by this repository. Version 0.1.0 is published as BigSaltyMan/moonbsdiff; [publication evidence](docs/release-0.1.0.md) distinguishes uploaded source, package and later documentation. The source repository is [BigSaltyMan/moonBSDiff](https://github.com/BigSaltyMan/moonBSDiff).

From a configured native toolchain, run:

```sh
moon info
moon fmt
moon fmt --check
moon check --target native --deny-warn
moon build --target native
moon test --target native --deny-warn
python scripts/check_format_vectors.py
python scripts/check_compression.py
python scripts/check_apply.py
git diff --check
```

The [CI workflow](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml) runs source checks and compares the generated interface; results must be matched to their checkout SHA. [Dependency probe](testdata/dependency-probe/README.md) explains historical and repeatable bzip2 tests and their limits. The project tests cover configuration, error data, integer encoding and envelope boundaries; the fixed 31-input interoperability inventory now has actual bidirectional acceptance: native 31 pairs per direction, JS/Wasm-GC 19 each. Generation now enforces cumulative logical quotas and bounded encoder emissions; these are not whole-process CPU or peak-memory guarantees. See [compatibility evidence and replay](docs/compatibility.md). See [compression contracts and verification](docs/compression.md). See [format details](docs/format.md). [Licenses and upstream](docs/upstream.md).

[Fixed BSDiff 4.3 reference tools](tools/oracle/README.md) and [13 offline upstream fixtures](testdata/upstream/README.md) provide the fixed upstream patches used by the apply tests. Run `python scripts/generate_reference.py` for offline integrity verification. The upstream self-check is separate from the apply results above.

## Apply in memory

This example is executed in apply_test.mbt. It uses three complete empty bzip2 streams.

```moonbit
test "apply-memory-example" {
  let stream = b"BZh9\x17\x72\x45\x38\x50\x90\x00\x00\x00\x00"
  let patch = b"BSDIFF40" +
    b"\x0e\x00\x00\x00\x00\x00\x00\x00\x0e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" +
    stream +
    stream +
    stream
  let limits : @moonbsdiff.Limits = {
    max_old_bytes: 1024L,
    max_new_bytes: 1024L,
    max_patch_bytes: 1024L,
    max_output_bytes: 1024L,
    max_decompressed_bytes: 4096L,
    max_control_instructions: 128L,
    max_sort_work: 1L,
    max_match_work: 1L,
  }
  assert_eq(@moonbsdiff.apply(b"", patch, limits), Ok(b""))
}
```

BSDIFF40 does not identify the old file. A wrong old file is not guaranteed to cause an error; verify expected old/output hashes externally. See [apply behavior and limits](docs/apply.md). See [application-stage acceptance and measurements](docs/apply-acceptance.md) for default selection, actual tested scales and unmeasured peak memory.

Use the public default configuration in memory:

```moonbit
let limits = @moonbsdiff.Limits::for_apply()
// old_bytes and patch_bytes are supplied by the caller.
let result = @moonbsdiff.apply(old_bytes, patch_bytes, limits)
```

Explicit caller-selected Limits continue to work. The three targets each passed the final 73-test application-stage collection; the independent upstream case count remains 13.

An internal [binary suffix-array index](docs/suffix-array.md) is now implemented using prefix doubling and counting sort, including the empty suffix and unsigned binary-byte ordering. It has no public API; it supports the generator described below; the native CLI is described below. Application defaults are unchanged and must not be used as generation defaults.

Internal [suffix matching and segment planning](docs/matching.md) now provide longest-match queries, offset scoring, forward/backward selection and overlap adjustment. Matching scans reuse the existing suffix index and can produce old-data reuse with nonzero residuals. These components remain private and now feed residual encoding and patch assembly through public diff. The native CLI is described below.

## Generate and apply in memory

The following test is executed in diff_test.mbt. These explicit limits are illustrative for this small input, not measured generation defaults. Limits::for_apply() has sorting/matching placeholders and must not be treated as a generation default.

```moonbit
test "diff-memory-example" {
  let limits : @moonbsdiff.Limits = {
    max_old_bytes: 4096L,
    max_new_bytes: 4096L,
    max_patch_bytes: 8192L,
    max_output_bytes: 4096L,
    max_decompressed_bytes: 16384L,
    max_control_instructions: 256L,
    max_sort_work: 1000000L,
    max_match_work: 1000000L,
  }
  let old = b"MoonBSDiff example version 1"
  let new = b"MoonBSDiff example version 2!"
  let patch = match @moonbsdiff.diff(old, new, limits) {
    Ok(b) => b
    Err(_) => abort("diff failed")
  }
  assert_eq(@moonbsdiff.apply(old, patch, limits), Ok(new))
}
```

[Generation behavior and verification](docs/generation.md) describes the initial native generator result and resource boundaries. [Bidirectional compatibility](docs/compatibility.md) now records 31 independent input pairs (13 fixed upstream plus 18 deterministic random-edit pairs), with actual upstream generation -> MoonBSDiff apply and MoonBSDiff diff -> upstream bspatch: native 31 per direction, JS/Wasm-GC 19 per direction. Every executed restoration matched the original new bytes. Run `python scripts/run_conformance.py` for offline inventory checks, and explicitly add `--run` for the external matrix with verified reference tools. CI runs offline inventory/comparator checks and a separate real-reference job; consult the matching SHA for current results. BSDIFF40 does not authenticate the old file; verify expected hashes externally.


## Generation defaults and development status

`Limits::for_diff()` supplies old/new/output 64 KiB each, patch 128 KiB, total raw
blocks 256 KiB, 4096 controls and 8388608 units each for sorting and matching /
generation. Explicit Limits continue to work. [Measurement and boundary evidence](docs/generation-resources.md)
explains the 16 measured samples, cumulative accounting, fixed Writer workspace,
copying and unmeasured peak memory. Independent caps may reject a size-compliant
pair. Application defaults are unchanged and may need a larger patch cap to apply
incompressible generated patches. The public default entry is exercised in
`diff_resources_test.mbt`:

```moonbit
let limits = @moonbsdiff.Limits::for_diff()
let result = @moonbsdiff.diff(old_bytes, new_bytes, limits)
```

The [repository development plan](docs/development-plan.md) preserves the source
plan dated 2026-11-04 and records the completed 16-stage first-release scope.
The native CLI is implemented, and 0.1.0 package audit, publication and independent
registry consumption are recorded separately. No tag or GitHub Release was created.


## Native CLI

With the pinned MoonBit toolchain, Python 3 and a native C compiler configured
(on Windows, use an MSVC developer shell), run from repository root:

```sh
python scripts/build_cli.py
```

No Mooncakes installation is required to run the built executable. The build
copies it to `_build/bin/windows/moonbsdiff.exe` or `_build/bin/linux/moonbsdiff`.
Python is a build/test tool, not a runtime dependency of the CLI.

```powershell
& .\_build\bin\windows\moonbsdiff.exe --help
& .\_build\bin\windows\moonbsdiff.exe --version
& .\_build\bin\windows\moonbsdiff.exe diff "old file.bin" "new file.bin" "update.patch"
& .\_build\bin\windows\moonbsdiff.exe patch "old file.bin" "update.patch" "restored file.bin"
```

```sh
./_build/bin/linux/moonbsdiff diff 'old file.bin' 'new file.bin' 'update.patch'
./_build/bin/linux/moonbsdiff patch 'old file.bin' 'update.patch' 'restored file.bin'
```

**Unreleased CLI additions (target 0.2.0, absent from published 0.1.0):**

```sh
./_build/bin/linux/moonbsdiff diff --max-old-bytes 256KiB --show-limits
./_build/bin/linux/moonbsdiff patch --show-limits
```

Eight explicit byte/count/work caps can override the unchanged defaults. Options
precede paths, `--` permits leading-hyphen paths, and display mode accepts no
files and performs no IO. Byte units are case-sensitive B/KiB/MiB; count/work
values have no units. Patch rejects sort/match options. The reader and core use
the same validated configuration; raising one cap leaves every other cap intact.
See the [full CLI option table](docs/cli.md#cli-overrides-unreleased-target-020).
This does not expand measured size or memory/CPU guarantees.

**Header-only inspection (also Unreleased, target 0.2.0):**

```sh
./_build/bin/linux/moonbsdiff inspect testdata/upstream/replace/patch.bin
./_build/bin/linux/moonbsdiff inspect --json --max-patch-bytes 256KiB testdata/upstream/replace/patch.bin
```

Reports format, patch/declared-target sizes and compressed intervals. It reads a
bounded patch (default 128 KiB), creates no output and does not decompress or
restore. `header-only` and all unperformed checks are explicit; JSON byte counts
and offsets are decimal strings with no Int64 precision loss. See [real output
and schema](docs/inspect.md). Inspect performs no manifest/identity/deep verification; use verify below for supplied-manifest content checks.
The minimal library `inspect_header`/read-only `PatchInfo` API is new in this
unreleased source and leaves diff/apply/defaults unchanged.

**Optional external manifest (0.2.0 Unreleased):**

```sh
./_build/bin/linux/moonbsdiff diff --manifest update.json old.bin new.bin update.patch
```

The separate [SHA-256 manifest](docs/manifest.md) binds the exact buffers used by
diff and the returned patch, with string byte counts and actual tool metadata.
The patch remains BSDIFF40. Outputs are checked for conflicts and delivered patch
first, manifest second, without replacement; partial failure keeps the patch and
reports manifest incomplete. This is not an atomic pair, a signature or publisher
authentication. Expected manifests must come from a trusted channel. Verify and checked restoration are available below. Published 0.1.0 is unchanged.

**Content verification and checked restoration (0.2.0 Unreleased):**

```sh
./_build/bin/linux/moonbsdiff verify --manifest update.json old.bin update.patch
./_build/bin/linux/moonbsdiff patch --manifest update.json old.bin update.patch restored.bin
```

Verify requires a manifest, bounds its read to 16 KiB, rejects malformed schema/
duplicate/unknown keys, checks old/patch identities, actually applies in memory,
and checks restored size/hash without writing a final file. Checked patch reuses
that pipeline and delivers only after success. Input hashing and apply share the
same buffers. Inspect remains header-only, and unmanifested patch is unchanged.
[Manifest policy](docs/manifest.md) defines limits, strict decimal-string sizes,
metadata handling and failure stages. Hashes establish supplied-content consistency,
not publisher authenticity; trusted expected manifests are still required.

Paths containing Chinese characters or spaces must be quoted similarly.
Our order is `patch OLD PATCH OUTPUT`; upstream is `bspatch OLD NEW PATCH`.
Exit codes are 0 success, 2 arguments/configuration, 1 operation failure; errors go to stderr.
Existing outputs, including links/aliases of inputs, are refused. A target created
during delivery is also preserved. Linux output requires O_TMPFILE and /proc;
unsupported filesystems fail closed. There is no overwrite option or durability
promise. [CLI details](docs/cli.md) explain bounded reads, handle-based cleanup,
actual platform tests, source/version provenance and filesystem scope.

Without overrides, generation uses for_diff unchanged. CLI patch keeps for_apply's old/output,
decode and instruction caps but raises only its patch cap from 64 KiB to 128 KiB,
matching the generator; a real 66279-byte patch roundtrip is tested. The library
factories are unchanged. BSDIFF40 does not authenticate the old file or result;
verify expected hashes externally. Version output is generated from moon.mod.


CI coverage and evidence are detailed in [compatibility](docs/compatibility.md).
Linux explicitly checks/builds native, JS and Wasm-GC; test selections retain their
full/compact scopes. Windows/Linux native CLI jobs reuse the file contracts.
A separate real-reference job builds the locked C tools once and executes the
unchanged 31-input bidirectional matrix. `scripts/check_acceptance.py` rejects
zero tests, failed children and stale/incomplete reference evidence. Actual CI
results belong to its checkout SHA; historical reports are not current passes.
These are source checks, not registry-consumer or release acceptance.


## Executable examples

From this source checkout (registry library installation is shown below):

```sh
moon run cmd/example --target js
python scripts/run_examples.py
```

The first command runs the pure [memory example](examples/basic/README.md).
The second runs both new examples, builds two repository-owned Wasm-GC versions,
uses the official CLI to generate/apply a patch, and checks full bytes and fixed
independently compiled hashes. Requires pinned MoonBit, Node, Python 3 and a native
C compiler; Windows uses an MSVC developer shell. Every run has a fresh ignored
`_build/examples/run-<nonce>` directory and prints sizes, hashes and `EXAMPLES PASS`.
A failure exits nonzero. [Wasm update instructions](examples/wasm-update/README.md)
include CLI reuse and exact flags. These are demonstrations, not a benchmark,
registry-consumer result or package release. Small-data patches can be larger.

## Benchmark and first-release scope

[Five fixed native-release process benchmarks](docs/benchmarks.md) record raw timings,
input hashes, patch sizes and a same-input BSDiff 4.3 comparison. These include
startup and file IO; core API time and reliable peak memory were not measured.
Validate the retained record offline with `python scripts/benchmark.py --verify`.
The 0.1.0 feature scope is frozen; see [CHANGELOG](CHANGELOG.md) and the
[development plan](docs/development-plan.md). Completed package audit, final-source
CI, Mooncakes publication and independent consumer results are in the
[0.1.0 publication record](docs/release-0.1.0.md). No prebuilt CLI download is provided.

## Release acceptance

0.1.0 release preparation and exact source/package/CI identity rules are in
[acceptance](docs/acceptance.md). The candidate is audited from `git archive`,
not a mutable working directory. Actual publication and registry installation
are recorded in [release 0.1.0](docs/release-0.1.0.md); candidate use is separately
labeled. There is no prebuilt CLI download or GitHub Release in this step.

## Install the published library

In an existing MoonBit module using the verified compiler baseline:

```sh
moon add BigSaltyMan/moonbsdiff@0.1.0
```

Add `"BigSaltyMan/moonbsdiff"` to the package's `import` block, then use the
public API shown above. Fresh-cache external Windows consumption passed
native, JS and Wasm-GC with full-byte restoration checks. Local Linux registry
bootstrap encountered a network failure; Linux source/CLI and three-target
candidate checks passed separately in CI. See the release record for exact
source/package identities and the distinction from the later docs commit.
