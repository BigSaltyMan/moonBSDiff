# Explicit larger-input policies (0.3.0 Unreleased)

This is new source-policy evidence, not a change to the released CLI 0.2.0
support statement or its download assets. Mooncakes 0.2.0 remains unpublished.
`Limits::for_diff()` still allows 64 KiB old/new/output, with its original
independent quotas. No algorithm, codec, compression level, public API, default
factory or dependency was changed for this step. The existing implementation
succeeded with explicit Limits; no optimization or general size guarantee is
claimed. 4 MiB and larger inputs were not evaluated.

## Complete policies

All byte values below are actual bytes, not decimal KB. Work and control values
are positive counts. The [machine-readable policies](../testdata/generation/scale-policies.json)
and [six-case measurements](../testdata/generation/scales.json) use these exact
values, chosen before execution and not increased after failures.

| Limits field | 256 KiB policy | 1 MiB policy |
| --- | ---: | ---: |
| max_old_bytes | 262144 | 1048576 |
| max_new_bytes | 262144 | 1048576 |
| max_output_bytes | 262144 | 1048576 |
| max_patch_bytes | 524288 | 2097152 |
| max_decompressed_bytes | 360448 | 1441792 |
| max_control_instructions | 4096 | 16384 |
| max_sort_work | 52429000 | 209715400 |
| max_match_work | 67108864 | 268435456 |

For a candidate byte cap n, the initial sorting allowance is 200*(n+1).
The existing index initializes at most 5*(n+1) entries, then charges at most
9*(n+1) per doubling round. At these caps, ceil(log2(n+1)) is 19/21, so this
allowance exceeds the declared sorting reservations (176/194 times n+1).
This explains the sort allowance, not every other stage or actual machine CPU.

The matching/generation allowance is 256*n: twice the original default policy's
128 work units per capped input byte. This was a bounded candidate derived from
the existing policy, not a theorem about worst-case matching. It provides about
3.79/3.36 times the largest observed matching count at these stages. Adversarial
or different edits may exhaust it. Counters are never reset or disabled.

Controls retain 4096 at the first stage and scale to 16384 at the second.
The aggregate raw cap is n+24*control_cap, covering the payload plus allowed
control triples. The patch cap is 2*n, about twice the observed random-patch
size; this is a policy allowance, not a worst-case bzip2 bound. Every independent
cap can still reject otherwise size-compliant inputs. Apply uses the same six
byte/control caps; sorting/matching fields are unused positive placeholders.

## Measured scope

Baseline production source: `59f9cada166db39c4d14fbd905c3ba80fa7d72ed`.
Platform: Ubuntu 24.04/WSL2, Linux 6.6.87.2-microsoft-standard-WSL2, x86_64,
glibc 2.39; AMD Ryzen 9 8940HX with Radeon Graphics. Compiler: Ubuntu GCC
13.3.0. SDK: moon 0.1.20261102 (ea07287 2026-11-02), moonc
v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102. Native release, default
compiler flags. No warmup, one effective measurement per input; 256 KiB completed
before 1 MiB began.

Each scale has three independent input pairs:

- Sparse: LCG32 high-byte output, seed 2026112301+n. XOR 85 into positions n/7,
  n/3, n/2, n-1 of the new input.
- Periodic: old byte i%7; new byte (i+3)%7.
- Random: old seed as above, independent new seed 2026112303+n. LCG32 is
  state=(1664525*state+1013904223) modulo 2^32, emitting state>>24.

All inputs have old=new length n. Original new data comes from these independent
recipes, never diff/apply. Input sizes/hashes, restored hashes and patch hashes
are in the measurement record. Every case asserted complete restored-byte
equality and unchanged old/new inputs.

| Case | Sort work | Match/generation work | Controls | Raw ctl/diff/extra bytes | Patch bytes | Generate s | Apply s |
| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |
| 256k-sparse | 6549844 | 2098554 | 1 | 24 / 262143 / 1 | 188 | 0.030820 | 0.006552 |
| 256k-periodic | 25953847 | 3259230 | 2 | 48 / 262141 / 3 | 165 | 0.058456 | 0.006587 |
| 256k-random | 6549844 | 17726809 | 1 | 24 / 1 / 262143 | 263849 | 0.225267 | 0.030150 |
| 1m-sparse | 25428860 | 8390143 | 1 | 24 / 1048575 / 1 | 197 | 0.126959 | 0.029736 |
| 1m-periodic | 114296441 | 15130592 | 2 | 48 / 1048573 / 3 | 168 | 0.279937 | 0.025875 |
| 1m-random | 25428860 | 79914824 | 1 | 24 / 1 / 1048575 | 1053978 | 1.055780 | 0.127085 |

The core monotonic clock surrounds one `generate_patch` (the unchanged actual
body called by public diff) and one public apply. It excludes input construction,
hashes, byte assertions, diagnostic block decoding, Python and compilation.
Explicit SortBudget/MatchBudget objects reveal the actual cumulative totals.
The measurement snapshot copies every production source byte unchanged and adds
only wbtest clock/SHA-256 imports; no root source/configuration is edited.

The record separately stores whole `moon test` invocation elapsed time, about
7.19–8.71 seconds on this WSL checkout, including frontend/startup, input setup,
hashing and diagnostics. It must not be described as pure algorithm time.
The first case also includes a low-quota/fresh-public-call probe outside core
timing. Single samples are not speed rankings or cross-hardware guarantees.

Per-phase work accounting distinguishes initialization/rounds and scan, raw
validation/encoding, compression-wrapper copies and final assembly. Total budgets
are read directly. Components other than total/initialization are derived from
actual block lengths and the unchanged reservation formulas; they are not
separately timed stage probes. The random 1 MiB case uses 70450559 scan units;
periodic 1 MiB sorting uses 109053556 round units. The observed scale growth did
not justify changing the implementation. It does not prove absence of all
pathological inputs. Bzip2 engine CPU remains outside the logical work counter.

## Memory evidence

GNU time `%M` records kernel maximum RSS for the `moon test` invocation and its
children: 14220/14584/14456 KiB for first-stage sparse/periodic/random, and
24576/24576/28816 KiB for the second stage. This is a per-process high-water
measurement over the invocation, not the sum of concurrently live processes,
not an isolated diff/apply peak, and it includes diagnostics. Sampling RSS was
not performed. **Core API peak memory was not measured.**

Separate structural estimates: index Int32 payload is 20*(n+1), approximately
5/20 MiB at the two caps; segment scalar payload can reach 24*control_cap,
98304/393216 bytes, excluding representation overhead. Raw arrays and immutable
copies can coexist (approximately 2*raw_cap logical bytes). Inputs, returned SA,
plans, raw/compressed blocks, fixed level-9 encoder workspace/emission and final
patch/copy can overlap; allocation lifetime/GC is not a hard process bound.
The existing bounded-emission and workspace derivation remains in
[generation resources](generation-resources.md). These estimates must not be
substituted for measured peaks or a strict process-memory guarantee.

## Public library use

In a package importing BigSaltyMan/moonbsdiff, the following 256 KiB configuration
uses exactly the fields compiled and executed by the native measurements:

```moonbit
pub fn roundtrip(old : Bytes, new : Bytes) -> Result[Bytes, @moonbsdiff.BsdiffError] {
  let limits : @moonbsdiff.Limits = {
    max_old_bytes: 262144L, max_new_bytes: 262144L,
    max_output_bytes: 262144L, max_patch_bytes: 524288L,
    max_decompressed_bytes: 360448L, max_control_instructions: 4096L,
    max_sort_work: 52429000L, max_match_work: 67108864L,
  }
  match @moonbsdiff.diff(old, new, limits) {
    Err(e) => Err(e)
    Ok(patch) => @moonbsdiff.apply(old, patch, limits)
  }
}
```

For 1 MiB substitute the entire second column of values, not only the input cap.
The same limits are valid for apply; its sort/match quotas are unused. The machine
policy also provides apply limits with those two placeholders set to 1.

## Actual CLI commands

The following options/operands were executed by the two random-case CLI replays
([record](../testdata/generation/scale-cli.json)); run in a new directory containing
only your selected old/new inputs. Use the native release executable built from
this source, replacing `moonbsdiff` with its path. Existing outputs are refused.

```sh
moonbsdiff diff --max-old-bytes 262144 --max-new-bytes 262144 \
  --max-output-bytes 262144 --max-patch-bytes 524288 \
  --max-expanded-bytes 360448 --max-controls 4096 \
  --max-sort-work 52429000 --max-match-work 67108864 old.bin new.bin update.patch
moonbsdiff patch --max-old-bytes 262144 --max-new-bytes 262144 \
  --max-output-bytes 262144 --max-patch-bytes 524288 \
  --max-expanded-bytes 360448 --max-controls 4096 old.bin update.patch restored.bin

moonbsdiff diff --max-old-bytes 1048576 --max-new-bytes 1048576 \
  --max-output-bytes 1048576 --max-patch-bytes 2097152 \
  --max-expanded-bytes 1441792 --max-controls 16384 \
  --max-sort-work 209715400 --max-match-work 268435456 old.bin new.bin update.patch
moonbsdiff patch --max-old-bytes 1048576 --max-new-bytes 1048576 \
  --max-output-bytes 1048576 --max-patch-bytes 2097152 \
  --max-expanded-bytes 1441792 --max-controls 16384 old.bin update.patch restored.bin
```

The random patches exceed the CLI's original 128 KiB patch read cap, so patch
must explicitly receive the matching patch cap. Patch rejects sorting/matching
options. CLI default factories and all no-overwrite/filesystem guarantees remain
unchanged. These explicit policies do not retroactively enlarge any release's
platform or input guarantee.

## Replay and checks

With the pinned SDK, Python 3, native compiler and GNU time available on Linux:

```sh
python3 scripts/generation_scale.py --measure-stage 256k --output _build/scale256.json
python3 scripts/generation_scale.py --measure-stage 1m --prior _build/scale256.json --output _build/scale-all.json
python3 scripts/build_cli.py --release
python3 scripts/generation_scale.py --replay-cli _build/bin/linux/moonbsdiff --stage 256k --case random
python3 scripts/generation_scale.py --replay-cli _build/bin/linux/moonbsdiff --stage 1m --case random
python3 scripts/generation_scale.py --verify-report
```

Output report files must not already exist. Each run uses a new ignored log
directory and isolated temporary source snapshot; CLI replay uses fresh system
temporary files, verifies complete bytes, and cannot overwrite user files. It
prints actual effective configurations/commands. Timeouts, build/exit failures,
missing/duplicate results or any byte mismatch fail rather than skip. The second
stage requires a complete first-stage record matching the current production
sources. Fixed-report verification checks recipes/hashes, policies, counts and
CLI command/output identities without rerunning measurements.

Local scope: six measured pairs, one low-sort rejection (1310725 requested vs
1 remaining, Sorting/sort_remaining, no fake location), one fresh small public
diff/apply recovery, and two public CLI random-pair replays (four commands).
There are six independent input pairs, not eight. No old CLI/IO/library/random
matrix, C oracle, large historical compression probe or resource benchmark was
rerun. JS/Wasm-GC and Windows large-scale execution were not measured; core
algorithms were unchanged. The scale collection has one explicit Linux task
without absolute timing thresholds. Starting with Commit 24, ordinary pushes
verify these historical records against their original Git source hashes;
they do not remeasure the large cases or claim old timings for current code.
To request remeasurement, use workflow_dispatch with run_generation_scales=true.
New temporary reports still require matching current source identities between
stages. The compact [index-reuse API evidence](diff-index.md) is separate from
this historical scale acceptance. Publishing remains outside these source steps.
