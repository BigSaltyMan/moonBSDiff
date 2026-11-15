# File-based bounded patch application (0.4.0 Unreleased)

This source-only native path is explicit:

```sh
python scripts/build_cli.py --release
./_build/bin/linux/moonbsdiff patch --stream OLD_FILE PATCH_FILE OUTPUT_FILE
# Windows: .\_build\bin\windows\moonbsdiff.exe patch --stream OLD_FILE PATCH_FILE OUTPUT_FILE
```

Options precede paths, `--` ends options, duplicates fail. Existing application
limit options apply unchanged. For example, a patch larger than the CLI's default
128 KiB requires `--max-patch-bytes 256KiB` before the paths. Old/new/output,
expanded bytes and instruction caps remain independent; streaming does not widen
Limits' positive Int-indexable byte fields or alter the default factories.
Parameter/configuration failures exit 2; read/format/decode/execution/delivery
failures exit 1 on stderr; success is silent and exits 0.

Only `patch` accepts `--stream`. It rejects `--manifest` and `--show-limits`.
`verify` and checked `patch --manifest` keep their existing memory path, binding
hashes to the actual Bytes used by apply. This file path neither authenticates
old data nor claims a consistent input snapshot. It does not implement streaming
generation, progress, cancellation or a wall-clock deadline. Published CLI 0.2.0
assets and Mooncakes packages are unchanged.

## Feasibility and ownership

The original strict decoder accumulates the final RLE expansion and the complete
stream. The dependency Reader was not used: its semantics are not this adapter's
strict contract. The narrow adaptation retains the pinned Huffman/MTF/inverse-BWT
transform, separates its bounded RLE-domain block from final RLE emission, and
adds refillable Bits plus StreamReader. The original memory decoder uses that
same transform with its original whole-buffer RLE driver. See the attributed
[adaptation lock and patch](../internal/bzip2/README.md).

Three readers own independent absolute positions inside the Control, Diff and
Extra intervals. Each compressed refill is at most 4096 bytes and cannot cross
its interval. Pausing preserves bit accumulator, RLE-domain position, pending
run/value, block CRC, combined CRC and shared reservation accounting. Runs reserve
up to 259 expanded bytes before any output/CRC growth; pending output is emitted
in later bounded pulls without reserving it again. No prefix is decoded twice.
A reader that raised an error is discarded, never resumed.

The native adapter opens two regular input files, prechecks their measured sizes
against effective caps, and reads a maximum 32-byte header. Root
`inspect_header_prefix(header, actual_patch_bytes, max_patch_bytes)` reuses the
existing envelope parser; it does no IO, target allocation or stream validation.
This one pure helper is the only new root API. The file executor is native CLI
code; the root library never acquires native IO dependencies.

Old-file reads use checked absolute Int64 offsets with 64-bit off_t on Linux
(compile-time assertion) or LARGE_INTEGER on Windows. Read lengths are at most
4096 and checked against the opened size before seek/pread. A negative cursor is
never narrowed or negated until a chunk overlap proves it lies in -4096..-1.
Outside-old bytes contribute zero, addition is modulo 256, and x/y/output/cursor
advancement is checked before the corresponding action. Zero-output triples are
legal; instruction count is checked before fetching each triple.

## Retained buffers and budgets

| Object | Logical bound |
| --- | --- |
| Header/control triple | 32 / 24 bytes |
| Compressed input refill | 4096 bytes per reader |
| Final decoded pull | 1..4096 bytes; control reads require exactly 24 |
| Old-file read / output write | At most 4096 bytes each |
| Retained RLE-domain block | At most 100000 * stream level bytes per reader (900000 max) |
| Active block transform | BWT symbols, inverse permutation, intermediate plain arrays: each at most 100000 * level entries; bounded tables/selectors |

All three readers can retain a block concurrently. Only one block transform runs
at a time; scratch arrays and conversion copies can coexist with the other
readers' retained blocks. Chunk assembly also creates bounded Array/Bytes copies.
There is no array sized by restored-file size or whole decoded control/diff/extra
length. No whole patch is read, including during header parsing. The process and
runtime may retain freed allocations; these are logical structure bounds, **not
measured peak process memory**. RSS and reliable peak memory were **not measured**.

All readers share one cumulative expanded-byte budget. Each also enforces a
stream-output cap: diff/extra at declared target size, controls at
min(Int.max, 24 * instruction cap), with multiplication guarded before conversion.
Internal zero remaining permits only zero expansion. The target is checked against
both max_new_bytes and max_output_bytes before temporary output creation.
Control count and decoded budgets are never reset on block/stream switches.
Bzip2 internal CPU is not a complete work/time budget. Format-bounded block
workspace may be allocated even when little decoded budget remains.

## Strict completion and safe delivery

Reaching declared output size is insufficient: each reader is pulled again to
force final block CRC, actual end marker, combined CRC and exact compressed
interval consumption. Remaining decoded control, diff or extra bytes fail.
Only final-byte padding bits are ignored, as in memory apply; garbage and a
second stream are rejected. Empty targets undergo the same completion checks.
Invalid data may have written temporary bytes before a late CRC failure, but
those bytes are never published as a successful output.

The file layer calls the existing delivery function with a synchronous populate
callback. This follows the documented MoonBit native FuncRef/closure adapter
[ABI](https://docs.moonbitlang.com/en/stable/language/ffi.html#callbacks), validated
with the fixed compiler, rather than relying on a private closure layout.
Population, all format checks and input-handle closing happen before writer
closing and no-replace publication. A callback error, read error, write error or
input/writer close error prevents publication. Temporary creation failure closes
inputs even if the callback was never invoked. Context is single-operation native
CLI state, cleared after the synchronous call; no concurrent/reentrant API is
promised.

Windows retains handle-based exclusive creation, close-before-no-replace rename
and identity-based cleanup. Linux retains O_TMPFILE/proc first, and only its
existing capability branches use the guarded ext-filesystem private-directory
fallback. See [Linux delivery](linux-delivery.md) for permission/threat assumptions
and possible retained objects when ownership cannot be proved. Final paths are
never deleted as rollback. A post-publication cleanup/close error can still report
failure with a delivered output, as before. No power-loss durability or universal
filesystem support is added.

Concurrent file mutation is outside a consistent-snapshot guarantee: opened
handles avoid repeatedly resolving inputs, and short reads fail, but contents can
change between reads where the platform permits writers. This is why manifest
streaming is refused rather than claiming the old same-Bytes hash guarantee.

## Narrow validation record

2026-11-15, Windows x86_64/MSVC Build Tools 2022 and WSL Ubuntu 24.04 x86_64,
release CLI, fixed moon 0.1.20261102 (ea07287 2026-11-02),
moonc v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102. No SDK/dependency
upgrade. New tests are `scripts/test_cli_stream.py`,
`cmd/main/stream_wbtest.mbt`, `internal/bzip2/stream_wbtest.mbt` and the one pure
header-prefix regression. Commands:

```sh
python scripts/test_cli_stream.py --exe _build/bin/linux/moonbsdiff
moon test cmd/main/stream_wbtest.mbt --target native --deny-warn
moon test internal/bzip2 --filter 'stream pull*' --target native --deny-warn
moon test format_prefix_test.mbt format_wbtest.mbt --target native --deny-warn
```

The Python set has five groups on each platform (42 invocations in its final
definition). Local complete runs passed 41 invocations per platform; the final
short-control assertion and stricter limit diagnostics were then validated by
rerunning only their two affected groups on each platform. Final full-set evidence
is produced by CI. Two independently constructed cases restore 16384 and 131072 bytes, each
using 184 triples, including zero-output seeks and negative/partial old overlap.
Python Random v3/randbytes with seed 20261115026 + target size supplies residuals
and extra bytes; expected target comes from the independent byte/control recipe,
not memory apply. Memory apply is an additional byte-for-byte comparison. Raw
expanded totals are 20800 / 135488 bytes; patches 17471 / 132935 bytes. A separate
131072-byte repeat target exercises paused final RLE expansion. Identities:

| Target bytes | New SHA-256 | Patch SHA-256 |
| --- | --- | --- |
| 16384 | 954eff91e3367b9cf3264d29e46fd9e90ace8fdc3ad4766df6d5002dd53c7bcb | b39a85ef5a81b4f0eb0eb1daf0dec52082b88ca6983937cc560f215bbde384a4 |
| 131072 | ced896e131e2fbfc9b67c7a34be3f224d5937e82d8afef111f199491428c7b35 | 3843730ba1bf459149d21e3c4b3e112af565f651de8f6b54a4cba93e85cf7922 |

Old size 5120, SHA-256 4345361085c730756d843f13849c50a996fe2f1fac3a7ac05fb063bb743a423e.
Hash identity for compressed bytes is scoped to the recorded Python/libbz2
producer; future producers need not make byte-identical compressed streams to
restore the same independent expected target.

The groups also check block/stream CRC corruption in all three intervals,
truncation, garbage, concatenation, empty-stream tail, redundant decoded data,
extreme and overflowing cursors, exact/one-short effective caps, failure/recovery,
input preservation, existing output and incompatible arguments. Private delivery
checks cover interrupted/short/zero-progress writes, writer-close and publication
failure, competing final target, cleanup and a fresh call. Linux additionally
forces the existing guarded compatibility delivery through the same callback.
Source-refill tests use 1/7/4096-byte compressed chunks and 31-byte output pulls,
including within-run pauses and budget-before-expansion assertions.

Directly affected memory compression compact regressions and the new pull test
run on native/JS/Wasm-GC; file CLI tests are Windows/Linux only. No claim of JS or
Wasm file IO is made. Existing historical matrices, oracle, full CLI/IO suites,
large compression probes, resource measurements and benchmarks were not rerun
locally. CI adds the small new paths to existing jobs; the final source SHA and
actual remote run identity belong in the completion report, not a self-referential
source commit. This is no release and does not implement Commit 27.
