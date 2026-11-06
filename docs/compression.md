# Bounded bzip2 block adapter

## Scope and integration

`compression.mbt` is private root-library plumbing. `compress_block` calls moonzip 0.3.5 at fixed level 9, including a real empty stream. `decompression_budget(limits)` validates the existing Limits and creates one budget from `max_decompressed_bytes`; a future apply operation must create it once and pass the same object to Control, Diff and Extra. `decompress_block` accepts one compressed interval, a per-call output cap (0..2147483647), shared budget, stage, and interval start offset. A zero internal cap or remaining budget permits only zero output. Negative values never mean unlimited.

No diff/apply or product CLI exists yet. Control instructions and exact consumption of decompressed control/diff/extra data belong to Commit 5/6. No library call invokes an external process. Root `pkg.generated.mbti` is unchanged; the internal decoder package has a generated implementation interface.

## Original gaps and chosen adaptation

Rechecked source: moonzip `bzip2.mbt::decode_all` calls `read_block` before its limit check; `decode.mbt::read_block` performs final RLE expansion into an output array before returning. `bits.mbt::Bits.used` exposes loaded bytes only within the package. Public bunzip2 does not return consumption. `stream.mbt::Reader.push` checks the current push's output rather than a lifetime total.

The native dependency-gap test actually reproduced both exposed symptoms: bunzip2 accepted a valid stream plus garbage, and Reader(limit=100000) returned 110080 bytes across 100-byte pushes. The late RLE limit is established by the actual source order; no claim is made that an external memory profiler measured the original excess allocation.

The encoder remains in the fixed dependency. Only decoder/bit-reader/CRC/randomisation source is copied under `internal/bzip2/`, retaining the original copyright and Apache-2.0 LICENSE. The cache is unchanged. The source lock and patch document the subset and modifications; Huffman, MTF and inverse BWT are preserved. A small local driver and error bridge replace the original one-shot driver. This does not upgrade or rewrite the compression engine.

## Single-stream boundary and checksums

The decoder parses the real end marker and combined CRC after checking each block CRC. Successful output requires exactly one stream; an additional complete byte, garbage or another stream is rejected, including after an empty stream. Truncated headers, block data, end marker and CRC are errors.

Bits are consumed most-significant first. Logical consumption is `8 * loaded_bytes - held_bits`, computed in Int64. The consumed byte extent is its ceiling divided by eight; it must equal the interval length. This is computed from actual decoder state, not marker searching, prefix retries or re-compression. Final-byte alignment bits are ignored, regardless of their value; no extra zero-bit rule is imposed. A test changes only those bits and confirms acceptance. Internal reads retain at most seven unconsumed bits and do not speculatively load beyond the requested field.

## Budgets and workspace

Before every final RLE segment is emitted, Meter checks `segment <= per_call_cap - produced` and `segment <= shared_remaining`. Only then does it deduct the shared budget, update accounting, update CRC and push output bytes. The completed block is checked again against remaining per-call space before appending it to the aggregate. Remaining capacity uses subtraction, and all Int64-to-Int conversions are range checked. Shared counters are checked so emitted plus remaining cannot overflow Int64.

Budget use is cumulative across actual bzip2 blocks and across the three selected intervals; failures do not refund already emitted work. A failed call returns only an error, never partial output. A new operation gets a fresh budget. Tests check exact caps, one byte short, zero remaining, three calls consuming one budget, accounting before a rejected segment, and a fresh successful call after failure.

The RLE-stage input, BWT block, inverse-permutation and intermediate plain buffer are separately bounded by `100000 * level` (at most 900000 entries). Selectors are bounded by their 15-bit field (32767), groups by six, alphabet by 258, and code lengths by twenty. Intermediate MTF run checks occur before array extension. These workspaces may be allocated even with a tiny output cap: they are format-bounded workspace, not output bytes. Multiple output representations/copies can coexist. No strict process peak-memory, whole-process CPU or wall-clock guarantee is claimed. Future generation work must add its own resource protection.

## Errors and offsets

Truncation maps to TruncatedData; invalid header/level/marker/trailing bytes to InvalidField; coding and CRC failures to DecompressionFailed; budgets to ResourceLimitExceeded; invalid parameters to InvalidConfiguration; interval-position overflow to IntegerOverflow. Stage and block label identify Control/control, Diff/diff or Extra/extra.

Offsets are patch-file absolute byte positions: interval start plus the decoder-relative position, with checked addition. Truncation uses bytes actually available at the failed read. Some decode failures report the reader's current position, not the original corrupt bit. CRC failures have offset None because the source error does not supply an exact location. Per-call-cap errors give attempted produced bytes and cap; shared-budget errors use field `decompressed_remaining`, the current segment request as value, and remaining bytes as limit. They do not claim to know the stream's full expanded size.

## Reproduction and actual verification

Use the isolated moon 0.1.20261102 / moonc 0.10.19+bee578715 toolchain. On Windows native, initialize MSVC first. Commands are run from the repository root:

```sh
python scripts/check_compression.py
moon test --target native --deny-warn > native.log
python scripts/check_compression.py --log native.log --large
moon test compression_wbtest.mbt --filter 'compression-compact*' --target js --deny-warn > js.log
python scripts/check_compression.py --log js.log
moon test compression_wbtest.mbt --filter 'compression-compact*' --target wasm-gc --deny-warn > wasm-gc.log
python scripts/check_compression.py --log wasm-gc.log
```

Default fixture verification is offline and also checks embedded compressed literals and adapted-source hashes. `--generate` explicitly rebuilds the small binary fixtures and corresponding byte literals with Python bz2. Expanded boundary inputs are reconstructed algorithmically, not stored as huge source arrays. The largest compressed fixture is 1885 bytes. Python output verification requires eof, empty unused_data, exact bytes and BZh9; `--large` additionally requires the large encoder result and rejects missing results.

2026-11-06 local execution: native full suite passed 17/17 once (12 existing + four compact contracts + one large-boundary test). Adding the Limits-constructor and level-range assertions was followed by a 4/4 compact native rerun; the added dependency-gap test separately passed 1/1. There are now 18 logical tests; no second full 18-test run is claimed. JS and Wasm-GC each ran only the four compact tests, all passed. Large-boundary and dependency-gap tests were excluded there.

Python -> MoonBit: eight compact level-1/9 fixtures plus four boundary fixtures decoded correctly on native; compact fixtures passed on JS and Wasm-GC. Headers with levels 1 through 9 were accepted under their valid block ceilings. Parsed block counts were 1/2 for near/cross level-1 inputs (99980/110080 bytes) and 1/2 for near/cross level-9 inputs (899980/921600 bytes). The large sample was tested only once in native. MoonBit -> Python: five level-9 results on native (including the 921600-byte case), four compact results on each other target, all strictly validated.

The 13 Commit 3 offline fixtures passed one integrity check. The source-adaptation patch reproduced all five copied files (line endings normalized), and negative checks proved the Python comparator rejects a missing large result and a damaged stream. The C oracle was not rebuilt and its patches were not regenerated. Historical dependency probes were not rerun. CI now includes these compression checks but has not run remotely. This is bzip2 interoperability, not full BSDIFF40 interoperability. Detailed command counts are in testdata/compression/results.json.
