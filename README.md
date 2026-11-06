# MoonBSDiff

MoonBSDiff is a planned MoonBit reference port of BSDiff 4.3 for binary diffs and patches. The current stage implements structured errors, `Limits::validate`, and internal BSDIFF40 integer and envelope parsing. Patch generation, application and a native CLI are planned, not implemented. Compression will reuse the third-party moonzip bzip2 package.

The `Limits` fields for old, new, patch and output buffer sizes are byte counts in 1..2147483647, bounded for Int indexing. `max_decompressed_bytes` is an aggregate byte count, `max_control_instructions` counts instructions, and `max_sort_work` / `max_match_work` count algorithm-defined work units; each is a positive Int64. The work unit definitions and actual enforcement will be established with the algorithms. No defaults are supplied; application and generation defaults will be measured in Commit 6 and Commit 11. Validation means only that a configuration is legal, not that runtime resource protection exists. No cross-field relationships are imposed.

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
git diff --check
```

The initial CI runs these checks and compares the generated interface; remote CI has not yet run. [Dependency probe](testdata/dependency-probe/README.md) explains historical and repeatable bzip2 tests and their limits. The project tests cover configuration, error data, integer encoding and envelope boundaries; no patch application, interoperability or general runtime resource protection is claimed. See [format details](docs/format.md). [Licenses and upstream](docs/upstream.md).
