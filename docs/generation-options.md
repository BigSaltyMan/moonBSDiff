# Compression preferences (0.3.0 Unreleased)

Only bzip2 compression level is configurable. No codec, matching strategy or
parallelism setting is added. This is new source functionality; published CLI
0.2.0 assets/tags and Mooncakes 0.1.0 are unchanged. Mooncakes 0.2.0 is unpublished.
The source module/CLI version metadata remains 0.2.0; use the source SHA to
identify these unreleased features, not the version string alone.

## Library API

```moonbit
pub(all) struct DiffOptions {
  compression_level : Int32
}
DiffOptions::default() -> DiffOptions // level 9
DiffOptions::validate(DiffOptions) -> Result[Unit, BsdiffError]
diff_with_options(Bytes, Bytes, Limits, DiffOptions) -> Result[Bytes, BsdiffError]
DiffIndex::diff_with_options(DiffIndex, Bytes, Limits, DiffOptions)
  -> Result[Bytes, BsdiffError]
```

In a package importing BigSaltyMan/moonbsdiff:

```moonbit
let limits = @moonbsdiff.Limits::for_diff()
let options : @moonbsdiff.DiffOptions = { compression_level: 6 }
let patch = @moonbsdiff.diff_with_options(old, new, limits, options)
let index = @moonbsdiff.DiffIndex::build(old, limits)
// After handling build's Result:
// index.diff_with_options(new, limits, options)
```

Ordinary diff and DiffIndex::diff retain their original signatures and forward
to the same implementation with default level 9. Index construction has no
compression preference. Every target can choose its level independently, and
neither preferences nor budgets are retained on the index.

Levels are integers 1..9. Invalid values are rejected before sorting/matching
or encoding, including before the dependency's clamping Writer constructor.
The structured error is InvalidConfiguration / Configuration, field
compression_level, the actual value, upper limit 9, with no fabricated block or
offset. The documented lower bound is 1. Invalid options or a quota failure do
not invalidate an existing index. Limits remain resource policy, not preferences.

All three control/difference/extra streams use the same validated level, including
empty streams. Patch bytes are still BSDIFF40, with exactly one complete bzip2
stream per interval; each stream can contain multiple internal blocks. Apply
reads the level from each stream and requires no options parameter.

## Source-built CLI

Build using the pinned toolchain and `python scripts/build_cli.py --release`:

```sh
moonbsdiff diff --compression-level 1 old.bin new.bin update.patch
moonbsdiff diff --compression-level 6 --manifest update.json old.bin new.bin update.patch
moonbsdiff patch --manifest update.json old.bin update.patch restored.bin
moonbsdiff diff --compression-level 6 --max-old-bytes 256KiB --show-limits
```

Actual display from the last command (no file IO):

```text
operation: diff
max_old_bytes: 262144 bytes
max_new_bytes: 65536 bytes
max_output_bytes: 65536 bytes (target buffer; patch has separate cap)
max_patch_bytes: 131072 bytes
max_decompressed_bytes: 262144 bytes (raw control + diff + extra)
max_control_instructions: 4096 instructions
compression_level: 6 (generation option; bzip2)
max_sort_work: 8388608 work units
max_match_work: 8388608 work units (matching + generation)
```

Only diff accepts --compression-level. It uses positive ASCII decimal parsing,
no units/signs/fractions; range validation precedes narrowing. Missing, duplicate,
invalid or inapplicable values exit 2, stdout empty, diagnostic on stderr.
Options precede operands; -- terminates option parsing. --manifest and limit
overrides compose normally. No resource cap is implicitly increased. The display
labels the compression level as a generation option, not a resource limit.

Manifest schema 1 is unchanged, with no compression-level field added. Its patch
hash binds the actual returned compressed bytes. Existing strict consumers
remain compatible; patch/verify determine levels from the stream. Hash manifests
do not authenticate a publisher. Output checks/delivery and partial-failure
semantics are unchanged.

## Workspace, emission and work proof

The exact moonzip 0.3.5 Writer/engine source hashes were rechecked against the
existing encoder-source record. There is no upgrade, engine rewrite or copied
decoder adaptation. Writer::new itself clamps values; project validation occurs
first. For level k, the RLE block threshold is 100000*k. A pending atomic RLE
flush can cross by at most four bytes, so retained block length is at most
100000*k+4, no larger than 900004 for supported levels.

One 32768-byte push adds at most 40960 RLE bytes plus a pending atomic flush,
less than the smallest 100000-byte threshold. Even if it first completes an old
block, it cannot complete a second. Finish flushes one run and at most one
block. The level-9 emission bit bound in [generation resources](generation-resources.md)
is monotone in block length and its alphabet/table constants do not increase at
lower levels. Thus the same conservative <3 MB single-emission bound applies
to every supported level; this is not a measured allocation or zero-overshoot
claim at the patch quota.

BWT uses four L-element Int32 arrays, per-round class buckets, last column and
MTF/Huffman structures bounded by actual block length and fixed alphabets.
Their structural scale decreases with the selected block threshold, but
collection, capacity overhead and simultaneous live buffers remain runtime
dependent. Level 9 timing/peak observations are not measurements of other levels.
No API peak-memory measurement was made here.

The same PatchBudget covers header plus all three streams. Each emission is
checked before wrapper accumulation; matching/generation reservations still
cover feed/finish calls, copies and final assembly. Smaller levels do not reset
or bypass counters. Original raw/control/index/platform checks remain active,
and default Limits are unchanged. Complete bzip2 CPU, wall-clock and whole-process
peak memory are not bounded by these logical quotas.

## Actual targeted evidence

Pinned SDK: moon 0.1.20261102 (ea07287 2026-11-02), moonc
v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102. Native evidence used
Ubuntu 24.04/WSL2 x86_64, Ryzen 9 8940HX and GCC 13.3, native release.
The [small record](../testdata/generation/compression-options.json) includes
production/encoder file hashes, inputs, patches, all nine results and oracle hash.

Same old input `abracadabra/00/ff` (13 bytes), new
`abraCHANGED/00/ff/abracadabra!` (25 bytes); slash separates displayed fragments,
not actual bytes. One post-build call per level, no warmup, ordered 1..9.
Core monotonic clock brackets public diff_with_options, including validation,
index and compression; excludes process startup, compilation, apply, assertions,
input construction and hex export.

| Level | Generate microseconds | Patch bytes |
| --- | ---: | ---: |
| 1 | 61.617 | 169 |
| 6 | 22.663 | 169 |
| 9 | 22.713 | 169 |

Sizes are equal and timings are tiny single samples, with first-call/order and
noise effects. These do not show a dependable speed or ratio advantage. Data
were not changed to manufacture a tradeoff. No RSS or reliable peak memory was
measured in this step.

All nine native exported patches were independently parsed/applied by Python
integer/bz2 checks: exact expected BZh level in all three streams, CRC/EOF,
no unused compressed data, complete controls/payload and original-new bytes.
A native level-1 case with empty old and 100010 period-251 new bytes produced
a 1038-byte patch. The strict decoder parsed control/diff/extra block counts
1/0/2 and exact stream ends; block evidence is not a magic-byte search.
Cached hash-verified BSDiff 4.3 bspatch restored the level-6 small patch and
level-1 cross-block patch exactly; the oracle was not rebuilt locally.

Default and explicit level 9 are byte-identical. The CLI also compared its
default patch to the frozen Commit 19 abc/00/ff fixture, not only a self-roundtrip.
Native/JS/Wasm-GC each passed 3 compact API tests, including all levels on both
ordinary/indexed generation, empty streams, invalid configurations, deterministic
calls and low-patch-quota failure followed by successful index reuse.
Windows/Linux each passed 3 new CLI tests (20 invocations), including nondefault
manifest generation, verify/checked patch, strict rejection and effective display.
One native existing cumulative-work regression confirms default accounting.

Reproduction:

```sh
moon test diff_options_test.mbt --target native --deny-warn
python3 scripts/test_cli_options.py --exe _build/bin/linux/moonbsdiff
python3 scripts/check_diff_options.py --native-evidence --oracle --output _build/options-new.json
python3 scripts/check_diff_options.py --verify-record
```

The native helper uses a byte-identical production snapshot with test-only core
clock import, fresh temporary paths and exact nonzero result parsing. It checks
exits/timeouts/output bytes; requested output must not already exist. --oracle
only reuses verified tools. --oracle-record selects an existing verified build
record (CI uses _build/oracle/build.json after its existing reference task).
It never downloads/builds an oracle. CI runs this boundary/evidence only once in
the Linux reference job, while compact API and CLI checks reuse existing target
jobs. No local old matrix, 138-case interoperability, historical large compression
probe or scale measurement was rerun. This step does not publish or enter Commit 26.
