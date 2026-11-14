# Reusable old-file index (0.3.0 Unreleased)

`DiffIndex` suits one old version used to generate patches for several new
versions. Ordinary `diff(old, new, limits)` keeps its signature, defaults and
one-shot behavior. Both routes use the same matching/encoding/compression/header
pipeline; sorting and matching algorithms have not been replaced or tuned.
No CLI command, serialization, file IO, global cache or eviction policy is added.
This source API is not a claim about published CLI 0.2.0 or Mooncakes 0.2.0.

```moonbit
DiffIndex::build(Bytes, Limits) -> Result[DiffIndex, BsdiffError]
DiffIndex::diff(DiffIndex, Bytes, Limits) -> Result[Bytes, BsdiffError]
```

The generated root interface exposes only this type (private fields) and these
two methods. The old Bytes, suffix Array, budgets and counters have no public
getters or mutable fields.

## Runnable example

With this source checkout and pinned SDK on PATH:

```sh
moon run examples/index-reuse --target js
```

Expected success output: `one old index, two restored targets: PASS`. Any build,
generation, application or full-byte comparison failure exits nonzero. This is
a source example, not registry consumption. Its complete executable source is
[main.mbt](../examples/index-reuse/main.mbt):

```moonbit
fn main {
  let old = b"old\x00\xff-data"
  let limits = @moonbsdiff.Limits::for_diff()
  let index = match @moonbsdiff.DiffIndex::build(old, limits) {
    Ok(value) => value
    Err(_) => abort("index build failed")
  }
  let per_target = { ..limits, max_sort_work: 1L, }
  for expected in [b"old\x00\xff-DATA!", b"prefix-old\x00\xff-data"] {
    let patch = match index.diff(expected, per_target) {
      Ok(value) => value
      Err(_) => abort("indexed generation failed")
    }
    let restored = match @moonbsdiff.apply(old, patch, limits) {
      Ok(value) => value
      Err(_) => abort("apply failed")
    }
    if restored != expected {
      abort("restored bytes differ from predefined target")
    }
  }
  println("one old index, two restored targets: PASS")
}
```

## Construction and per-target limits

Construction validates every Limits field and rejects old size above
max_old_bytes before retaining it in a completed object or allocating the SA.
The existing suffix builder checks n+1, Int narrowing, bucket sizes and work
reservations before allocation. One SortBudget accumulates over initialization
and every round. Any failure returns Err, not a partially usable index.

No target exists at construction. Positive max_new/output/patch/raw/control and
match-work fields must remain valid configuration, but do not impose unrelated
old-file size relationships. `Limits::for_apply()` is not a nonempty-index build
policy: its sorting allowance 1 is an application placeholder. Use for_diff or
an explicit build configuration.

Each indexed generation revalidates all configuration and the bound old size,
new size, output size, minimum patch size and unavoidable raw size. A new
MatchBudget then accumulates through scanning, raw encoding, compression-wrapper
copies and final assembly, exactly as ordinary diff does. Control count,
aggregate raw bytes, bounded encoder output and final patch caps remain active.
Limits can differ between construction and calls; building under a larger old
cap does not authorize a later call with a smaller old cap.

Only build actually sorts and charges max_sort_work. Indexed generation does
not create a SortBudget or charge historical sorting again. The field still
must be positive, as must every other Limits field. Zero/negative never means
unlimited. No budget or partial output is saved on the index. Success or failure
cannot spend the next call's allowance or replace its per-call encoder state.

Reviewed call paths:

```text
DiffIndex::build -> build_suffix_array (one cumulative sorting budget)
DiffIndex::diff  -> generation_preflight -> new MatchBudget
                -> generate_indexed_patch -> select_segments / encode / package
ordinary diff   -> generate_patch -> generation_preflight -> build_suffix_array
                -> the same generate_indexed_patch
```

`generate_indexed_patch` has no sorting budget parameter and no index-builder
call; it only reads the existing suffix Array. Tests pair a nonempty build's
Sorting/sort_remaining failure at allowance 1 with successful indexed calls
using that allowance. Source routing plus this contract demonstrate reuse
without adding public debug counters. No speed benchmark or acceleration factor
was measured.

## Ownership and memory

The index holds the supplied immutable Bytes through the safe MoonBit API, not
a mutable Array or temporary BytesView. The pinned core exposes no safe Bytes
setter; its from_array conversion preserves immutability when a caller retains
the source Array. Tests mutate that Array after construction and mutate an
Array extracted from a returned patch; old bytes and later patches remain
unchanged. Deliberate unsafe reinterpretation/FFI mutation is outside this safe
API contract; no such mechanism was introduced for tests.

For n old bytes, logical long-lived payload is n old bytes (shared with the
caller, not copied here) and n+1 Int32 suffix positions, approximately
n+4*(n+1) bytes plus object/array headers. It includes the empty suffix at n.
Construction also needs the existing four N-element Int32 arrays and
max(N,257) count buckets, N=n+1. Only the final SA survives in DiffIndex;
the other arrays become eligible for reclamation. No construction budget is
retained.

Every generation owns its plan, raw arrays, Writer/decoder state, compressed
blocks, final patch and MatchBudget. Those are not stored in DiffIndex. Holding
an index deliberately extends the old Bytes and SA lifetime. Dropping references
makes them reclaimable according to the runtime; immediate reclamation or return
of memory to the OS is not promised. There is no total-process peak-memory or
complete bzip2 CPU guarantee. Existing [resource boundaries](generation-resources.md)
still apply. Concurrent use/thread safety is not claimed or tested.

## Targeted evidence and CI

Baseline: `1995c5934ec7c08b714e68fbf68d4cf7dae49406`.
Pinned SDK: moon 0.1.20261102 (ea07287 2026-11-02), moonc
v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102. Native, JS and Wasm-GC
each passed the same five new compact public-API tests:

```sh
moon test diff_index_test.mbt --target native --deny-warn
moon test diff_index_test.mbt --target js --deny-warn
moon test diff_index_test.mbt --target wasm-gc --deny-warn
```

They cover two targets bound to one old index, restoration and ordinary-diff
equivalence, deterministic reuse, safe aliases, empty old/target, construction
configuration/old/sort errors, per-call old/new/output/patch/raw restrictions,
and exact per-call work followed by one-short failure and recovery. Errors check
kind, stage, field, value, limit and missing block/offset. The exact one-byte
reservation derivation is reused from the existing resource test, now proving
successive indexed calls each receive the full independent allowance.

One native existing exact-cumulative-work regression was executed because the
shared generation entry was refactored. No suffix-sort or matching algorithm
was changed. No local old CLI/IO/library matrix, interoperability, larger-scale
measurement, compression sample or historical benchmark was rerun. Native
check/build, format/interface review and the executable JS example were checked.

CI's existing native collection includes the new tests once; one compact step
adds this API collection on JS/Wasm-GC, and the example runs once on JS. The
historical scale evidence is now checked against its recorded original Git
source bytes. Large scale remeasurement is available only by workflow_dispatch
with run_generation_scales=true; ordinary pushes do not rerun it or treat old
timings as measurements of the new implementation. The default factories,
dependency pins, format, compression level and published tags/assets are
unchanged. This step does not publish or proceed to Commit 25.
