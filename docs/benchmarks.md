# Small native-release benchmark and scope freeze

This is a five-case process benchmark, not an algorithm ranking or broad performance
guarantee. Source baseline: `1feee0c04f857fa95ebda0d04646d7952a624d3e`. Core/CLI algorithms
and dependencies are unchanged in this step. Raw retained samples, exact inputs,
limits, oracle build record and executable identities are in
[testdata/benchmarks/results.json](../testdata/benchmarks/results.json).

## Fixed method

Five cases were selected before timing: same, sparse (four XORs), period-7 shift,
independent pseudo-random data at 4096 bytes, plus Commit 14's real 3962-byte v1/v2
Wasm-GC modules. Rules reuse LCG32 v1: seeds 2026110801+4096 and
2026110803+4096, sparse positions n/7, n/3, n/2, n-1 (integer division), XOR 85.
Module inputs are independently rebuilt with the existing fixed manifest and
`wasm-gc --release --strip`; this is not another Wasm demonstration or fixture set.
No case was changed/removed after seeing results. All fit existing generation
size limits. Quotas were never raised.

One warmup pair and three measured generate/apply pairs per implementation per
case: 80 child invocations total, 60 retained timings. Execution order is fixed
MoonBSDiff then upstream; no random scheduling/thermal-control claim is made.
Median of three is the summary; all three raw samples remain in JSON.

CPU: **AMD Ryzen 9 8940HX with Radeon Graphics**. OS: `Linux-6.6.87.2-microsoft-standard-WSL2-x86_64-with-glibc2.39`, architecture
`x86_64`, Python `3.12.3`. Compiler: `gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0`.
Toolchain is moon 0.1.20261102 (ea07287), moonc v0.10.19+bee578715,
moonrun 0.1.20261102 (2026-11-02 builds). Native release is built through
`scripts/build_cli.py --release`, default C flags; compilation is outside timings.

Each elapsed sample uses Python perf_counter immediately around subprocess.run:
process startup, argument parsing, binary IO, operation, close and delivery are
included. Python full-byte validation/hash computation and builds are excluded.
**Core API time is not measured.** Both implementations use the same Linux paths,
inputs and timer boundary. MoonBSDiff additionally enforces its normal limits,
identity checks and safe delivery; the old C reference does not provide the same
safety contract. Differences cannot be attributed purely to the algorithms.
Tiny process measurements are sensitive to scheduling/cache/WSL noise; no speed
multipliers, significance claim or cross-platform guarantee are inferred.

Files use Linux /tmp on the WSL filesystem. An initial premeasurement setup attempt
on Windows-backed /mnt/d failed at O_TMPFILE before any timed pair completed;
its inputs were not changed, and no unsafe IO fallback was introduced. The final
measurement used /tmp consistently for both tools. Re-running creates fresh
output names and retains artifacts under a unique /tmp directory plus ignored
_build/benchmarks records. No existing output is overwritten.

MoonBSDiff uses unchanged for_diff quotas (old/new/output 65536, patch 131072,
raw 262144 bytes, 4096 controls, 8388608 sort/match units). Apply uses the CLI's
for_apply policy with only patch cap 131072: old/new/output 1048576, decoded
2097152 bytes, 16384 instructions. The JSON's old_new_output_bytes describes the
generation policy. C uses the unchanged fixed BSDiff 4.3 tools with static bzip2
1.0.8, level 9, without MoonBSDiff quotas. Tools were reverified against existing
source/lock/product hashes and **not rebuilt**. Their full hashes/configuration
are retained in JSON; no alternative implementation is substituted.

## Actual medians

Times are milliseconds per process, patch sizes are bytes. Every measured and
warmup restoration was checked against the original new bytes in full. Each
implementation applies its own patch; this is not a new interoperability matrix.

| Case | Moon generate ms | Moon apply ms | Moon patch | C generate ms | C apply ms | C patch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| same-4096 | 7.943 | 8.203 | 137 | 4.742 | 4.802 | 137 |
| sparse-4096 | 7.758 | 8.355 | 181 | 5.016 | 4.548 | 181 |
| periodic-4096 | 8.755 | 8.072 | 164 | 5.581 | 4.155 | 147 |
| random-4096 | 10.652 | 8.186 | 4692 | 5.641 | 4.349 | 4693 |
| wasm-update | 7.779 | 7.463 | 146 | 4.631 | 5.205 | 147 |

In this environment the C processes were faster in all five cases. Patch sizes
vary by segmentation/encoder choices; equality is neither required nor evidence
of universal parity. The Wasm result is one tiny example, not a general advantage.
**Reliable peak memory: not measured. Sampled RSS: not measured.** Earlier sampled
RSS and structural buffer estimates are separate historical evidence, not peak
measurements for this benchmark.

## Reproduce and validate

On Linux/WSL with the fixed toolchain, Python 3, native compiler and existing
hash-verified oracle cache (see tools/oracle/README.md):

```sh
python3 scripts/benchmark.py
python3 scripts/benchmark.py --verify
```

The first command rebuilds only the release CLI/module inputs and measures the
five cases; it never builds the oracle. Missing tools, failed commands, timeouts,
missing outputs, byte differences or manifest/hash differences fail nonzero.
It writes a new ignored result, never silently updates committed expectations.
The second command checks committed input identities, result completeness and
median arithmetic offline without timings, old suites or reference execution.
CI runs only --verify, not benchmarks. This is source-checkout evidence, not
Mooncakes registry consumption. The existing CI still performs its own normal
functional/reference checks after push.

## 0.1.0 feature freeze

The first-release feature scope is frozen: no new format, directory synchronization,
network transport, GUI, tuning parameters, or expanded platform/resource promises.
Current diff/apply, strict BSDIFF40, native CLI and examples define the scope.
Remaining work is compatibility defects/necessary fixes, package audit, final
validation, Mooncakes publication, independent consumer verification and publication
records (Commit 16). This benchmark does not claim that those steps are complete.
Linux CLI still requires O_TMPFILE and /proc; there is no power-loss durability
promise. BSDIFF40 still does not authenticate the old file or recovered data.
