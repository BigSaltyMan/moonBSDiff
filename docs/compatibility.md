# Bidirectional compatibility acceptance

## Actual run (2026-11-07)

The starting source commit was `fa7d05eafde413f14b925c7288691a28a7e3236f`
on clean `master`. This step changes testing infrastructure, not library algorithms
or the public interface. The saved [run summary](../testdata/conformance/last-run.json)
identifies every library source/configuration file by SHA-256, the manifest, toolchain,
reference executables, generated patches and restored contents. Its run ID is
`9026c10804324313b65d83a32a881e8f`. The final commit is reported outside this document.

There are **31 independent old/new pairs**, not 138 independent cases:

| Target | Upstream bsdiff -> MoonBSDiff apply | MoonBSDiff diff -> upstream bspatch | Failures / required skips |
| --- | --- | --- | --- |
| native | 31/31 | 31/31 | 0 / 0 |
| JS | 19/19 | 19/19 | 0 / 0 |
| Wasm-GC | 19/19 | 19/19 | 0 / 0 |

All **138 restorations** were compared with the complete original new bytes.
The 69 MoonBSDiff exports also passed the existing independent Python BSDIFF40
parser, canonical-integer, level-9 single-stream, control and complete-consumption
checks. No equality of patch bytes or segment plans between generators was required.
There were no unexplained differences and no algorithm-failure regression was fabricated.

The JS/Wasm-GC compact matrix was fixed before execution: all 13 historical pairs
plus the six 128-byte random-edit pairs. Each intentionally excludes the 12 random
pairs with 512/2048-byte old inputs; these are outside its declared required set,
not successful executions. Native includes all pairs. See the exact target lists in
the [manifest](../testdata/conformance/manifest.json).

## Inputs and reference identity

The 13 Commit 3 pairs/patches remain unchanged in `testdata/upstream/`. They cover
empty inputs/targets, identical content, replacements, insertion, deletion,
prefix/suffix additions, all byte values, periodic data, block movement and fixed
random editing. Their old/new bytes and fixed C patches are hash-checked and reused;
the historical upstream patches were not regenerated.

Eighteen additional pairs use LCG32 v1, defined in
`scripts/conformance_cases.py`: update `(1664525 * state + 1013904223) mod 2^32`
and emit the high byte. Seeds `2026110701`, `2026110702`, `2026110703` respectively
produce old inputs of 128, 512, 2048 bytes. Each has six independent edits:
four sparse XORs, insert 17 bytes, delete up to 31 bytes, prepend 13 bytes,
append 19 bytes, truncate 23 bytes. Positions, XOR values and derived-stream seeds
are explicit in the manifest. The LCG has no dependency on Python's random module
or its version. Old/new sizes, hashes and all recipes are fixed. New bytes come
from these independent rules, never from MoonBSDiff. These small pseudo-random
binary inputs exercise low-redundancy data; no statistical randomness or universal
incompressibility claim is made. The manifest is checked against regenerated recipes
on every run, not silently refreshed.

The actual oracle is the existing unmodified **BSDiff 4.3** source build, running
in Ubuntu 24.04/WSL2 Linux x86_64 (`6.6.87.2-microsoft-standard-WSL2`). The fixed archive
SHA-256 is `18821588b2dc5bf159aa37d3bcb7b885d85ffd1e19f23a0c57a58723fea85f48`.
The [source lock](../tools/oracle/upstream.lock.json) and
[build record](../tools/oracle/verified-build.json) record source-file hashes,
GCC 13.3.0 commands and static bzip2 1.0.8. The shared identity checker rechecked
the lock, cached source files and both executable hashes:

```text
bsdiff  6c53a0ce59f2e249d9ba512512ec4cedf04dd846c9900c5075680f2133bf2ec8
bspatch d37b7c4ec800b4ec8aed6d581cc1ca704a4f51717334915f5e72d495e5976fd4
```

No reference download or rebuild occurred. Eighteen new patches were generated
once by real `bsdiff OLD NEW PATCH` and shared between target executions. Real
`bspatch OLD OUTPUT PATCH` ran separately for all 69 target-generated patches.
The historical generation helper and Commit 9 verifier now reuse this same
`scripts/oracle_identity.py` check; they retain their documented fixture/unit-test
roles, not a second definition of the bidirectional matrix.

MoonBit ran on Windows 11 AMD64 (10.0.26300), using the MSVC developer environment
for native and Node v24.18.0 for JS. The isolated toolchain was:

```text
moon    0.1.20261102 (ea07287 2026-11-02)
moonc   v0.10.19+bee578715 (2026-11-02)
moonrun 0.1.20261102 (ea07287 2026-11-02)
```

Windows Python was 3.14.6; WSL Python was 3.12.3. Only this environment is claimed.
The bridge explicitly supplies Limits: old/new/output 8192 bytes, patch 32768 bytes,
aggregate decompression 131072 bytes, 4096 instructions, sort/match work 100000000
each. These are test allowances, not measured generator defaults. `for_apply()`
is not used as a generation configuration.

## Runner and strict result protocol

`scripts/run_conformance.py` is a test runner, not a product CLI. Its default
action only checks the offline inventory. `--run` creates an exclusive, fresh
`_build/conformance/run-<nonce>/` directory, snapshots manifest/library identities,
materializes inputs, and generates a temporary black-box MoonBit test bridge.
An existing bridge file is refused. The bridge is removed afterward; its per-target
source and command logs remain in that run directory. The core library never
calls C or Python and gains no file-oriented API.

Every bridge result is exactly one `CONFORMANCE:` JSON line with these fields:

```text
schema, run_id, manifest_sha256, case_id, target, direction,
old_sha256, new_sha256, status, payload_kind, payload_hex
```

Schema is integer 1; other fields are strings. Payload is canonical lowercase
hex, with kind `restored` for direction A and `patch` for direction B. The parser
rejects duplicate JSON keys, unknown fields, noncanonical hex, unexpected stdout
and wrong types. Exactly one successful nonzero MoonBit test summary is required,
with its count equal to that target's declared cases. The result set must contain
exactly one row per required case/direction, the current run nonce and manifest,
the selected target, the fixed old/new hashes and status `ok`. Missing, extra,
duplicate, skipped or stale records fail the run.

The runner writes actual A output and actual B patch, independently parses the B
patch, and invokes C bspatch into a previously nonexistent output path. Process
exit codes, output existence and per-process timeouts are mandatory: 15 seconds
for a C case and 120 seconds for a MoonBit command or WSL phase. The runner fails
on tool/environment errors; it never substitutes a skip. Every restored output is
compared as bytes against original new data. Hashes identify artifacts; they do
not replace byte comparison. Materialized inputs and prepared patches are rechecked,
and library/manifest changes during the run fail. Each target's bridge is built
before collecting the strictly parsed execution stdout.

`results.json` retains actual payloads; `summary.json` records all patch hashes,
restored hashes and the full-results hash. Only the small summary is checked in as
`testdata/conformance/last-run.json`. Raw payloads, executables, caches and build logs
are ignored, not shipped. The snapshot is historical evidence, not a substitute
for rerunning the matrix after algorithm changes.

## Failure checks and replay

All **22** executor/protocol/comparator tests passed. Controlled temporary results
prove rejection of same-length corruption, truncation, missing/extra/duplicate
records, wrong target/direction/input/manifest identity, an old run nonce,
skipped status, unknown fields, malformed hex, boolean schema, duplicate JSON keys
and unexpected/missing/wrong stdout summaries. Controlled Python children prove
nonzero exit, timeout, missing output and preexisting correct-byte output all fail;
a fresh-output success path also passes. These tests do not send malicious patches
to the old C reference.

On a real failure, the runner retains request/phase failure JSON, complete old/new
inputs, available patches/restored files, generated bridge sources, commands,
exit status and stdout/stderr in the unique run directory. Raw bridge payloads
are retained in stdout even if result-set validation fails. Seed/edit parameters
are in the fixed manifest. Replay a single pair in a **new** directory:

```sh
python scripts/run_conformance.py --run --targets native --case rnd-2026110703-insert
```

Such reports say `subset/replay`, never full acceptance. No automatic shrinker is
implemented. Distinguish a `mismatch` from `process`, `timeout`, environment or
protocol failures before diagnosing an algorithm difference. Fixes for real
algorithm defects would be preserved under regression data; none was found here.

## Commands and remaining scope

From repository root with the isolated toolchain on PATH and native compiler
initialized, the actual full command was:

```sh
python scripts/run_conformance.py --run
```

On Windows it invokes the two reference phases through the existing
`wsl -d Ubuntu-24.04 -- python3 /mnt/d/project/moonBSDiff/scripts/run_conformance.py`
and fresh run directory. On Linux the same runner invokes Python phases directly;
Linux MoonBit execution was not verified in this step. A missing cache must first
be restored using the existing locked [build recipe](../tools/oracle/README.md);
`--oracle-record _build/oracle/build.json` selects its explicitly recorded products.
The runner does not download/build tools implicitly.

The associated offline checks passed:

```sh
python scripts/run_conformance.py
python -m unittest discover -s scripts -p test_conformance.py
python -m unittest discover -s scripts -p test_diff_verifier.py
python -m unittest discover -s scripts -p test_reference.py
python scripts/check_diff.py
python scripts/generate_reference.py
python scripts/check_format_vectors.py
moon test limits_test.mbt format_wbtest.mbt --target native --deny-warn
moon info
moon fmt
moon fmt --check
moon check --target native --deny-warn
moon build --target native
git diff --check
```

The two existing verifier suites passed 8 and 10 tests respectively; all three
Python suites (22/8/10) and the inventory check also passed under WSL Python 3.12.3,
matching the offline commands added to Linux CI. Native configuration/format
regressions passed 12/12. The 13 fixed fixtures and 9 integer vectors plus header
cases remain intact. Root `.mbti` has
no changes. CI adds offline inventory and comparator checks to ordinary library
checks, retaining the nonzero-test requirement. The explicit external reference
matrix is separate, not an automatic job that silently skips absent tools.
Remote CI has not been run; Commit 13 remains responsible for the full CI matrix.

No historical compression probes, large compression samples, application resource
measurements, C builds, old patch regeneration or unrelated full unit-test matrices
were repeated. JS/Wasm-GC larger random inputs remain untested here. Matching patch
bytes across generators/environments is not required for legal compatibility.

MoonBSDiff enforces its documented single-bzip2-stream and complete compressed/raw
consumption policy. A permissive reference may accept data that this policy rejects.
Legal-input interoperability is not a proof of safety for all hostile inputs; the
old C program is used only on legal generated patches. BSDIFF40 does not authenticate
the old file. Whole-generation resource protection and measured defaults remain
Commit 11; product CLI, publication and registry-consumer verification are pending.
