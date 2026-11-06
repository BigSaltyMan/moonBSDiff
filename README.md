# MoonBSDiff

MoonBSDiff is a planned MoonBit reference port of BSDiff 4.3 for binary diffs and patches. The current stage implements structured errors, `Limits::validate`, internal BSDIFF40 integer/envelope parsing, and a private bounded bzip2 adapter. The public apply API now restores strict BSDIFF40 patches. Patch generation and a native CLI remain planned. Compression uses moonzip 0.3.5 at level 9; strict bounded decoding uses its attributed, adapted sources under `internal/bzip2/`.

The `Limits` fields for old, new, patch and output buffer sizes are byte counts in 1..2147483647, bounded for Int indexing. `max_decompressed_bytes` is an aggregate byte count, `max_control_instructions` counts instructions, and `max_sort_work` / `max_match_work` count algorithm-defined work units; each is a positive Int64. The work unit definitions and actual enforcement will be established with the algorithms. Limits::for_apply() supplies conservative application defaults: old/new/output 1 MiB each, patch 64 KiB, total decompression 2 MiB and 16384 instructions. Sorting/matching fields are unused positive placeholders, not generation defaults; those remain for Commit 11. Validation means only that a configuration is legal, not that a complete patch operation has runtime resource protection. The private decoder now enforces per-call and shared decompression budgets. No cross-field relationships are imposed.

Errors provide a kind, stage, and optional block, offset, field, value and limit. Missing details are `None`. See the generated interface for exact types.

The verified local baseline is moon 0.1.20261102 and moonc 0.10.19+bee578715; the PATH default 0.10.13 is older and was not used for final validation. `moon.mod` declares moonzip 0.3.5; `moon tree` reports the resolved transitive versions in [sources](docs/upstream.md). No version lockfile was generated: `.mooncakes/.moon-lock` is an empty synchronization file, not a dependency lock. The resolved tree is a snapshot and should be rechecked; the transitive versions are not reproducibly locked by this repository. The proposed module name is not a publication or namespace availability guarantee; no repository URL is known.

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

The initial CI runs these checks and compares the generated interface; remote CI has not yet run. [Dependency probe](testdata/dependency-probe/README.md) explains historical and repeatable bzip2 tests and their limits. The project tests cover configuration, error data, integer encoding and envelope boundaries; apply is verified against the 13 fixed upstream patches; bidirectional BSDiff interoperability and whole-process resource guarantees remain unverified. See [compression contracts and verification](docs/compression.md). See [format details](docs/format.md). [Licenses and upstream](docs/upstream.md).

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

An internal [binary suffix-array index](docs/suffix-array.md) is now implemented using prefix doubling and counting sort, including the empty suffix and unsigned binary-byte ordering. It has no public API; matching scan, diff generation and CLI remain future steps. Application defaults are unchanged and must not be used as generation defaults.
