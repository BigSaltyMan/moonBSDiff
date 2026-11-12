# BSDIFF40 patch generation

## API and block construction

`diff(old_bytes : Bytes, new_bytes : Bytes, limits : Limits) -> Result[Bytes, BsdiffError]` is a pure in-memory API. It builds one existing suffix index, uses one existing matching scan, then encodes the selected ranges. No library operation performs file IO or calls an external process. Success returns complete Bytes; errors return no partial patch and inputs are not modified. Returned Bytes are immutable, constructed from a new final array; tests also check independent calls and mutable copies of results.

Every segment supplies (x=diff_length,y=extra_length,z=seek), encoded by the shared canonical eight-byte sign-magnitude codec. A validation pass checks contiguous new coverage, old-cursor correspondence, nonnegative/bounded spans, checked old cursor+x+z, and final coverage. Difference bytes are `(new-old+256) % 256`; extra bytes are copied from the exact new interval after its diff span. Selected diff bytes may be nonzero residuals. The byte counts are determined before allocating raw blocks. The generator rechecks actual emitted lengths against this plan. Empty new data produces no controls and no raw payload; empty old data legitimately uses extra-only content.

Each raw block goes through the existing fixed level-9 encoder. Empty blocks are real 14-byte empty bzip2 streams. The header is BSDIFF40 followed by actual compressed control length, actual compressed diff length and original new size. The checked final size is 32+three compressed lengths; only after it fits Int indexing and max_patch_bytes is the final patch array allocated. The smallest complete patch is 74 bytes. Integers are not written as two's complement, and no new compression parameters or format variants are introduced.

## Current resource model (Commit 11)

The initial generator's input/index/raw/final-size checks are retained and extended.
One sorting quota covers all array initialization and index rounds. One matching /
generation quota covers scanning, every query, raw encoding, compression-wrapper
copies and final assembly. The raw-byte cap is checked before indexing when its
minimum is known and before every segment push. Control output is exactly allocated.
Compression now uses the fixed dependency's public level-9 Writer with bounded feeds,
a shared three-stream patch-output cap, and bounded per-emission overshoot instead
of accumulating an entire compressed stream before its first check.

[Generation resources](generation-resources.md) specifies units, checked arithmetic,
error metadata, the <3 MB emission proof, workspace/copy lifetimes, 16 native release
measurements, measured `Limits::for_diff()` policy and regression results. This is
logical resource protection, not a process peak-memory or complete bzip2 CPU limit.
Explicit limits remain available and for_apply's work placeholders are unchanged.

## Independent parsing and external reference

The 13 unchanged old/new inputs are the existing upstream manifest cases. `scripts/check_diff.py --generate-tests` regenerates their black-box API test mapping; normal `python scripts/check_diff.py` validates it and input hashes offline. Tests check complete self-roundtrips, input snapshots and deterministic repeat generation. Additional contracts cover state isolation, input/output/patch/raw/control/sort/match limits and recovery, an executed README example, size preflights without giant allocations, invalid plans and residual wraparound (ff -> 00 encodes difference 01 inside a real selected diff span).

Generated tests emit DIFF:id:hex exactly once per independent case. `python scripts/check_diff.py --log PATH` requires all 13 results, rejects duplicate/unknown/missing IDs, independently checks canonical integer bytes and header boundaries, decodes each complete BZh9 stream with Python eof/unused_data checks, executes all controls using original old bytes, and compares complete restored bytes with original new.bin. It requires exact control/diff/extra consumption. Eight small verifier tests prove valid empty handling and rejection of truncation, trailing bytes, negative zero, wrong expected content and incomplete/duplicate/unknown export sets. Parser tests reuse small fixed upstream fixtures and do not run the oracle.

For external validation, the log is supplied from native tests and processed in WSL Ubuntu 24.04/Linux x86_64. The reused BSDiff 4.3 bspatch is the Commit 3 product, SHA-256 d37b7c4ec800b4ec8aed6d581cc1ca704a4f51717334915f5e72d495e5976fd4, built from the locked unmodified source with static bzip2 1.0.8. The tool rechecks lock identity, cached source hashes and executable hash against tools/oracle/verified-build.json before running it. No oracle rebuild or upstream patch regeneration occurred. The actual command is `bspatch OLD_FILE OUTPUT_FILE PATCH_FILE`; successful exit, output existence and full byte equality are required with a 15-second timeout per case. Old output is removed before invoking the process. Per-case inputs, newly generated patches, process logs and errors stay under ignored _build/diff-verification for diagnosis. Missing tools or failed processes fail the task, never skip it.

## Actual validation (2026-11-07)

Starting HEAD: 41f3a9fb227b35e3b4cf0c00991afabe833c478c, clean master. Isolated Windows toolchain _build/toolchain-0.10.19: moon 0.1.20261102 (ea07287 2026-11-02), moonc v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102 (ea07287 2026-11-02). Native uses the MSVC developer environment.

| Execution | Actual result |
| --- | --- |
| Final native generation selection | 20/20 tests, once |
| Final JS generation selection | 20/20 tests, once |
| Final Wasm-GC generation selection | 20/20 tests, once |
| Independent native parse | 13/13 complete restorations, 39 strict level-9 streams |
| Real upstream bspatch applied native exports | 13/13 full byte matches, one batch |
| Native compact suffix/matching regressions | 12/12 |
| Native format regression | 7/7 |
| Python verifier negative/positive tests | 8/8 |

The generation selection is diff_test.mbt + diff_vectors_test.mbt + diff_wbtest.mbt. It includes 13 independent upstream input pairs, four public API contracts and three white-box boundary tests. Target repetitions are not new independent cases. During development JS first ran an 18-test selection; two added contracts were then tested individually, followed by the final 20-test selection. The development JS log also passed 13-case independent parsing. After review strengthened failure-input snapshots and added nonempty truncation to state isolation, the affected limits/recovery and state-isolation tests were each rerun once on every target and passed 1/1. No production behavior changed during that strengthening. No JS/Wasm-GC external C application is claimed.

Saved native evidence is testdata/generation/native-results.json (case IDs, original input hashes, generated patch hashes/sizes, decoded controls and reuse statistics). Identical input uses 20 diff bytes and zero extra; block movement reuses all 1200 bytes with zero extra and negative seeks; periodic data uses 1500 diff bytes plus one extra; random editing uses 2048 diff bytes with 31 nonzero residuals. Other inputs may legitimately use all-extra output; no universal patch-size improvement is claimed.

Reproduce from repository root with the isolated toolchain on PATH and native compiler initialized:

```sh
moon test diff_test.mbt diff_vectors_test.mbt diff_wbtest.mbt --target native --deny-warn > _build/diff-native.log
python scripts/check_diff.py --log _build/diff-native.log
python -m unittest discover -s scripts -p test_diff_verifier.py
```

Then, for the actual existing Linux oracle, from WSL:

```sh
cd /mnt/d/project/moonBSDiff
python3 scripts/check_diff.py --log _build/diff-native.log --oracle
```

If the cached product is absent, use the existing locked tools/oracle/build.py restoration recipe and explicitly supply its new build record with --oracle-record _build/oracle/build.json. That is a separate restore/build operation, not part of ordinary offline testing.

moon info, moon fmt, moon fmt --check, native check --deny-warn/build, and git diff --check passed. Root .mbti adds only the actual diff function. Internal changes to prior components only remove unused annotations/comments now that generation consumes them; their algorithms and apply defaults are unchanged. CI adds the offline test map/parser checks, verifier tests and compact JS/Wasm-GC generation; the existing native full suite includes new tests and its log is independently parsed. Remote CI has not run, and no automatic oracle rebuild/download was added.

Skipped: historical probes, large compression boundary samples, apply resource measurements, full apply matrix and unrelated exhaustive suites. This is the generator's first 13-case native -> upstream application evidence; complete bidirectional random regression/comparator acceptance remains Commit 10. CLI and measured generation defaults remain unimplemented. BSDIFF40 has no old-file identity hash: applications must verify expected old/new hashes externally.


## Subsequent bidirectional/random acceptance

Commit 10 changes test infrastructure only. Its [compatibility report](compatibility.md)
records actual two-way external execution on 31 independent pairs: native 31 per
direction, JS/Wasm-GC 19 per direction, with full byte comparison and strict
comparator negative tests. That later evidence supersedes the native-only scope
of the initial Commit 9 external result above. The 13 original fixtures and
`native-results.json` remain unchanged historical evidence. Generator defaults
and whole-call resource guarantees remain Commit 11.


## Commit 11

The earlier "Commit 11 remains" statements above describe historical stage scope.
Generation defaults and cumulative logical quotas are now implemented; see
[generation resource acceptance](generation-resources.md). No new diff/apply
signature or public diagnostic API was added; the interface adds only for_diff.
The final unchanged-input bidirectional matrix is recorded in compatibility.md.

## Frozen first-release scope

Commit 15 adds [five small process benchmarks](benchmarks.md) using the existing
release CLI and default limits, without changing generation code or quotas.
These process timings include IO/startup and do not measure core API latency.
The API, strict format and resource contract are frozen for 0.1.0; remaining work
is necessary fixes and Commit 16 audit/publication/consumer verification.
