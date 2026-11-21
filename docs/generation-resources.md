# Generation resources and call isolation

Commit 25 adds [bzip2 generation preferences](generation-options.md), default 9,
valid 1..9, without changing Limits. The current Writer keeps each RLE block
within 100000 bytes per level. Work, copy, raw/control and aggregate patch quotas
remain active. See the emission bounds below and the historical level-1
measurements in the generation-options report.

Commit 23 adds [explicit 256 KiB/1 MiB source policies](generation-scales.md)
(0.3.0 Unreleased), with six new native-release measurements and two CLI replays.
The 64 KiB default factory, algorithms, work-unit definitions and guarantees below
are unchanged. The new policies are not a blanket size guarantee or a change to
the released CLI 0.2.0 assets. Historical Commit 11 measurements below were not
rerun or rewritten.

Commit 24 adds [DiffIndex reuse](diff-index.md). Construction checks old bytes
and charges one cumulative sorting budget; indexed generation revalidates target
limits and creates a fresh matching/generation budget. The old Bytes and final
SA are the only retained fields. Ordinary diff keeps its original pre-sort
preflight and budget semantics; both routes share generate_indexed_patch for
matching/encoding/packaging. Work-unit definitions below are unchanged. The
earlier measurement timings belong to their original source SHA, not to this
new API; only compact reuse/isolation contracts were run for Commit 24.

## Review and fixes (Commit 11)

Baseline: clean master, `d20524e42375d58058c2089a6643f780f44bb030`.
The error record and Limits fields are reused; only `Limits::for_diff()` is added
publicly. No dependency upgrade, copied-source change or C build is involved.

| Area | Existing protection | This step |
| --- | --- | --- |
| Inputs | validate configuration; old/new/output byte caps before index | Reused; unavoidable new payload + minimum control checked before indexing |
| Suffix workspace | n+1/index/bucket guards; one budget across rounds | Charge all four initialized arrays and bucket initialization before allocation; reject negative reservations |
| Matching | One shared budget for binary search, byte comparison, scoring, forward/backward/overlap and planner iterations | Reused; same object now continues through raw encoding, output copies and final assembly |
| Segment growth | Instruction and Int/24 caps before push | Also check new length + next triple's 24 bytes before every push |
| Raw blocks | Checked control multiplication, exact total before buffers | Preallocate exact control array; charge validation/encoding/copy visits before traversing/allocating |
| Compression | Whole-input one-shot output checked only afterward | Use the existing fixed public Writer, feed <=32768 bytes, check shared output cap before appending each emission |
| Final patch | Checked compressed length sum before final array | Retained; charge three final byte passes from the same generation budget before allocation |

`diff` creates fresh SortBudget and MatchBudget for every invocation. Private
`generate_patch` receives those exact objects. White-box instrumentation measures
this actual execution body, not a separate approximation of the algorithm.
Failed reservations do not deduct their amount. Completed work remains charged;
no query, sort round, encoder stream or stage switch resets either quota.
No mutable budget, index, encoder or result buffer is shared between public calls.

## Work units and arithmetic

`max_sort_work` counts logical Int32-array visits. For N=n+1, B=max(N,257):
empty input costs `1`; other initialization costs **4N+B** before five arrays
are allocated. Nonempty inputs then reserve **3N+257** for the initial length-1
counting sort and dense reranking (count `N`, prefix sum `257`, scatter `N`,
reranking `N`; returning early when `init_classes == N`). Each subsequent
doubling round reserves **4N+step+2K** (linear second-key placement `step+N`,
one stable first-key counting pass `2N+2K`, and dense reranking `N`, where `K`
is the current dense rank count; earlier Commit 11 reserved `5N+4K` for two
counting-sort passes per round). All arithmetic uses Int64 after N/K are proven
at most Int max. Allocation capacities, rank accesses, conditional
position+step, prefix totals and step doubling retain the existing index proofs.

`max_match_work` now means matching **and generation visit reservations**:

- One unit per existing scan/search iteration, common-prefix byte comparison,
  aligned score probe, forward/backward position, overlap position or segment push.
  An overlap position includes both old candidates; this is a logical position
  visit, not a promise of one machine instruction or one comparison.
- One unit per segment before plan validation.
- Before raw arrays, `4 * raw_bytes + segment_count`: one encode visit per
  segment and a conservative four visits per raw byte covering initialization,
  encoding, immutable conversion and small integer temporaries.
- One per Writer feed/finish call, and two per compressed byte before appending:
  accumulated-array write plus immutable conversion. Input feeding and Writer's
  internal bzip2 work are covered by input/format bounds, not separately counted
  as all internal CPU operations.
- Three per final patch byte before allocation: zero initialization, assembly,
  returned immutable Bytes copy. Small constant header/configuration work and
  runtime overhead are outside these logical units.

These declared reservations deliberately include conservative copy allowances;
they are neither instruction counts nor wall-clock limits. Sort and matching
categories have different owners; no sort visit is also charged as a matching
comparison. Current native tests derive the one-byte case independently:
**sort 528** (`4*2+257` pre-alloc + `3*2+257` initial length-1 sort+rerank with
early return); **matching/generation `52 + 5 * actual_patch_length`** (scan
drops from 10 to 9 because `search_match` reuses boundary LCP lengths instead of
rescanning after binary search; earlier Commit 11 derived `sort 1303` and
`53 + 5 * actual_patch_length`). Exact quotas pass; one less sort unit fails at
the initial length-1 sort reservation (`263` requested vs `262` remaining), and
one less matching unit fails at final assembly, proving the scan quota did not
reset at later phases. The `8388608` default caps in the table below remain the
historical Commit 11 policy baseline.

Each source length is an Int. The suffix builder proves n<=2147483646 before
n+1 and narrowing. Control count is checked before multiplication by 24.
Raw control/diff/extra each fit Int; their sum is <=3*Int max, so four times that
sum plus segment count fits Int64. Final size is checked with subtraction before
adding every compressed length and must fit both Int and max_patch_bytes. The
remaining-work subtraction accepts only nonnegative reservations; a counter never
adds toward overflow. Seek and cursor operations retain checked Int64 arithmetic.
No negative position is narrowed into an index without its existing range proof.

Resource errors retain kind/stage/field/value/limit. Work failures report requested
reservation versus remaining units (`sort_remaining`/`match_remaining`), not a
fabricated byte offset. Input/patch errors use Header; raw expansion uses Control;
segment count uses Matching. Locations that are not patch positions remain None.
Zero/negative public quotas fail configuration validation; internal zero is
exhausted, never unlimited. No partial patch is returned on failure.

## Fixed encoder and bounded output

The [internal Writer](../internal/bzip2/README.md) adapts the encoding subset
from `moonbitstack/moonzip@0.3.5` under Apache-2.0. Its source lock and
replay patch identify the files used by generation. The installed source hashes
in [encoder-source.json](../testdata/generation/encoder-source.json) identify the
upstream baseline used by historical measurement checks.

A four-byte run expands to five RLE bytes. Before folding in a run, the Writer
checks its actual encoded length. A run that fits exactly stays in the current
block. When it exceeds remaining space the Writer completes that block, then
counts the whole run in the new block's CRC. RLE length is at most
**100000 × level bytes**, or **900000** at level 9.

A 32768-byte push adds at most 40960 RLE bytes plus one pending run of at most
five RLE bytes. It can emit at most one block. Finish can emit a buffered block
followed by a second block of at most five RLE bytes, then the stream trailer.
The wrapper checks every returned emission before accumulating its bytes.

For a block of length L<=900000, MTF/RLE emits at most M=L+1 symbols. Code lengths
are 1..20 bits, <=6 tables with <=258 symbols, and <=ceil(M/50) selectors, each
at most 6 bits. A conservative per-block bit bound is
`20*M + 6*ceil(M/50) + 6*(5+258*39) + 395`.
Here 39 covers a 19-step two-bit length delta plus terminator; 395 covers block
marker, CRC, flags, origin, alphabet map and table counts. Applying the bound
to one maximum-sized block plus one five-byte block, headers, trailer and byte
rounding gives **less than 3 MB** for either push or finish.
Selector count <=18001 fits its 15-bit format field. BWT positions/steps remain
below this fixed block scale; Huffman alphabet/table arithmetic is bounded by
258 and 6. This derivation is specific to the pinned source, not a general
compression ratio assumption.

A single PatchBudget starts at 32 header bytes and is shared across all three
streams. Every returned emission is checked against remaining patch capacity
before appending to the wrapper's accumulator, and work is reserved before that
copy. Over-cap output stops immediately; later feeds/streams do not run. The
encoder may have produced **one bounded emission** before rejection. Sink arrays
and their returned Bytes copies may coexist. This is bounded overshoot/workspace,
not an instantaneous zero-allocation refusal at max_patch_bytes. It cannot first
build an unbounded compressed stream and only then reject it.

## Live buffers and guarantee limits

Inputs are caller-owned immutable Bytes. Suffix construction uses four N-element
Int32 arrays and B buckets: logical payload `4*(4N+B)` bytes. Returned SA can remain
live with the segment plan (four Int32 fields + one Int64 per segment, approximately
24 scalar-payload bytes each, excluding object/array representation). The other
sorting buffers become eligible for release; prompt collection is not promised.

Raw control/diff/extra sum to R=24*segments+new_size, checked before allocation.
Their arrays and immutable Bytes conversions can coexist (up to roughly 2R logical
byte payload). Generation retains raw blocks, prior compressed blocks, current
Writer state/emission and wrapper output while encoding subsequent streams.
The Writer retains an RLE byte block and its BWT/MTF/Huffman work: four L-element
Int32 sort arrays, per-round class buckets, L-element last column, <=L+1 symbols,
selectors and fixed-alphabet tables. Old round buckets can await GC. No exact
whole-engine peak-byte bound is inferred from simultaneously named locals.
Final patch array and returned Bytes may overlap with all previous arrays/blocks.

Logical payload limits and bounded engine blocks control growth. They do **not**
cap array capacity/headers, allocator overhead, retained garbage, stack, runtime,
process RSS, or all bzip2 internal CPU work. No strict timeout, real-time guarantee
or process peak-memory limit is promised. Allocation failure below configured
limits remains possible. Reliable peak memory and sampled memory were **not
measured** here; these structural descriptions are not measured peak values.

## Defaults and actual measurement

| Field | for_diff value | Selection basis |
| --- | ---: | --- |
| max_old_bytes / max_new_bytes / max_output_bytes | 65536 each | Actually exercised inputs through 64 KiB |
| max_patch_bytes | 131072 | Largest measured 66279; approximately 2x policy headroom |
| max_decompressed_bytes | 262144 | 64 KiB payload + up to 98304 control bytes with policy room |
| max_control_instructions | 4096 | Policy cap, paired low-limit exact/one-short growth tests; not a measured 4096-instruction generation acceptance |
| max_sort_work | 8388608 | Measured maximum 5834229; rounded policy headroom |
| max_match_work | 8388608 | Measured maximum 3875684; >2x policy headroom |

Sixteen samples use 4096 and 65536-byte scales: identical, four sparse XOR edits,
17-byte insertion (old shortened to keep new <=65536), 31-byte deletion, half-block
movement, repeated A with one trailing change, period-7 shift, independent random
old/new. LCG32 v1 seeds are 2026110801+n, 2026110802 (insert), 2026110803+n.
Exact recipes, input sizes/hashes, counts and generated patch hashes are in
[resource-measurements.json](../testdata/generation/resource-measurements.json).
No oracle or old fixtures are regenerated for measurement.

Measurements run on Windows 11 AMD64 (10.0.26300), isolated moon 0.1.20261102,
moonc v0.10.19+bee578715, native **release** with the existing MSVC developer
environment and default flags. First build is excluded. Each sample is a separate
post-build `moon test` process timed by Python perf_counter: startup, input
construction, one instrumented generate_patch call, apply/assertions and hex
export are included. Independent Python parsing is afterward and not timed.
The final 16 processes totalled 4.512587 seconds, ranging from 0.212040 to
0.456768 seconds each. These are process measurements, not isolated diff latency
or throughput rankings.
Exploratory candidate measurements are not substituted for the final defaults run.

Reproduce from repository root with the pinned toolchain on PATH and native
compiler initialized: `python scripts/measure_diff.py`. It refuses to overwrite
an existing temporary bridge, removes its own bridge finally, and writes ignored
logs/results under `_build/diff-measure/`. Offline report/hash checking uses
`python scripts/measure_diff.py --verify-report`; it does not repeat timings.

Defaults are independent fail-closed allowances for small in-memory generation,
not proof of acceptance of every 64 KiB pair. Explicit Limits remain supported.
Current application defaults allow 1 MiB each for old, new and output data and
128 KiB for the patch. The 66,279-byte patch in the recorded random case fits
this cap. Sorting/matching values of 1 in `Limits::for_apply()` remain apply-only
placeholders. No zero or negative value enables unbounded processing.

## Verification scope

Native resources + existing generator collection passed **26/26** (6 new tests,
20 existing). JS and Wasm-GC compact resource selection each passed **5/5**.
Native affected compact suffix/matching regressions passed **12/12**. Cases assert
exact errors/metadata, pre-index rejection, cumulative cross-phase work and stream
quotas, control/raw/final size exact/one-short, arithmetic guards without huge
arrays, immutable inputs, deterministic calls, fresh recovery and result isolation.
Bytes is immutable; mutating an extracted array cannot mutate another call.

One **new** native Writer integration test crosses its 900000-byte RLE boundary
using 900010 period-251 bytes. The strict library decoder and independent Python
bz2 both verified all bytes, CRC, EOF and absence of unused stream input. This is
a targeted test of the changed adapter, not a rerun of Commit 4's historical large
vectors. CI's native test log must contain exactly one GENSTREAM result; the
independent verifier fails if missing or duplicated. JS/Wasm-GC skip this scale test.

Final bidirectional acceptance uses the unchanged Commit 10 input matrix (31
independent pairs, native 31 per direction and JS/Wasm-GC 19 each), with strict
results and actual upstream execution; see [compatibility](compatibility.md).
Native CLI, cross-target CI and examples are implemented in Commits 12-14.
[Small process benchmarks](benchmarks.md) are recorded in Commit 15 without changing
these resource guarantees. Package audit, publication and independent registry
consumption remain Commit 16. No claim about all malicious inputs follows from legal-input
interoperability. BSDIFF40 still does not identify or authenticate the old file.
