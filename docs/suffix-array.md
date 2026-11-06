# Binary suffix-array index

## Route and source relationship

The internal `build_suffix_array` is an original MoonBit prefix-doubling implementation with two stable counting-sort passes per round. BSDiff 4.3 `bsdiff.c::qsufsort` and `split` were reviewed from the existing, SHA-256-verified local source (fc0a6e634ef77dcf14bf36c7b6d1e57ba1ac5c4809073dfaacb3b5f7ab277eb7). No oracle download or rebuild was performed. Its positions/inverse-ranks and empty-suffix result contract are the reference. No split code is translated: recursive group refinement, small-group comparisons and negative run markers are replaced by iterative radix passes and dense ranks. This choice makes array bounds, arithmetic and progression easier to audit in this toolchain; no measured speed advantage over qsufsort is claimed. No code from another suffix-array implementation was copied. BSDiff's original Colin Percival copyright and complete BSD notice remain in upstream.md and tools/oracle/BSDIFF-LICENSE.txt; the new MoonBit implementation is under the repository BSD-2-Clause license.

## Contract and invariants

For n bytes, return every position 0..n exactly once, in unsigned-byte lexicographic order; position n is the empty suffix and comes first. A shorter prefix suffix comes before a longer suffix. NUL and ff are ordinary input bytes, with unsigned values 0 and 255. Initial real ranks are byte+1 (1..256); the empty suffix rank is 0. A second component beyond the input is 0, never a real byte sentinel. After each round, dense ranks are 0..classes-1; the empty suffix remains the only first-component rank 0.

At step h, ranks describe h-byte prefixes (with explicit input ends). Stable sorting by second rank and then first rank sorts 2h-byte prefixes. Reranking equal pairs gives equal classes. Once classes=N=n+1, the entire suffix order is known and the array is returned. Otherwise h doubles. Before doubling, h < N-h must hold; when a prefix already spans the input, all suffixes must be distinct. A defensive internal error detects a violated progress invariant instead of overflowing or looping indefinitely.

Core code neither compares whole suffixes nor allocates suffix copies. Calls own all buffers, and the returned array is not reused. It does not mutate the input.

## Bounds, memory and work

`suffix_sizes` is separately testable without allocation. It validates max_entries in 1..2147483647 and n in 0..2147483646 before calculating N=n+1 in Int64. N must fit max_entries. Only then are lengths narrowed to Int32. Empty input consumes one setup work unit and returns [0] without other buffers. Nonempty input uses four N-element Int32 arrays (positions, radix scratch, ranks, next ranks) and one B=max(N,257)-element Int32 bucket array. Rank arrays swap roles without allocation. Logical array payload is 4*(4N+B) bytes, plus headers, capacities, allocator/GC and input; this is not a measured process-memory bound.

Both key ranges fit the bucket array: initial keys are 0..256 and later keys 0..classes-1. Counting-prefix totals never exceed N; scatter cursors address an element before their last increment reaches at most N. The second-rank lookup tests h <= n-position before adding. Classes and traversal indices stay within N. Doubling is performed only after h < N-h proves 2h < N, so Int arithmetic does not overflow. Work-charge arithmetic uses Int64; with N/K bounded by Int32 maximum, 5N+4K is representable.

An explicit internal SortBudget carries remaining Int64 work across calls, independent of Limits::for_apply. A negative budget is invalid and zero is exhausted, never unlimited. The builder reserves N logical setup units before allocation; it then reserves 5N+4K units before each whole round (two count/prefix/scatter passes plus reranking, where K is the current key count). These are defined algorithmic visit charges, not a count of every machine operation: allocator zeroing, branch/key lookups and runtime overhead are not separately metered. Failed reservations do not deduct that reservation; already completed stages stay charged. Size rejection does not consume the budget. This interface permits future generator-wide accumulation but does not establish full generation protection or a generation default. Caller-selected practical entry limits remain necessary; an arithmetic-valid request may still exceed available memory.

Time is O(n log n), from at most logarithmically many O(N+K) rounds, with O(n+256) auxiliary space. Neither peak memory nor performance relative to upstream has been measured.

## Independent verification

The test-only insertion sort compares original bytes and lengths directly. It does not use ranks, radix helpers or grouping. Small cases compare the entire returned array and separately check length N, range, uniqueness/completeness, empty first, and every adjacent pair's strict lexicographic order. Six hand-auditable vectors also check the test comparator: empty, ff, banana, 00 ff 00, AAAA, aba. Binary cases include increasing/decreasing 0..255, NUL repetition, 00/ff periodic data and long common prefixes.

Random generation is an explicitly defined UInt32 LCG, state=(1664525*state+1013904223) mod 2^32, emitting the high byte. Compact tests use lengths 0..63 and seed 20261106+i. Native exhaustive tests enumerate all 3280 strings of lengths 0..7 over {00,01,ff}. These include overlaps with compact cases; repeated target runs do not increase independent input counts.

Native scale checks use lengths 1024, 4096 and 16384: all-ff has the complete expected array [n,n-1,...,0]; period-7 data has an independently constructed complete order by byte and decreasing position. Random input uses seed 20261106 and full permutation/adjacency checks, plus deterministic repeated construction. Mutation of one returned array is tested against a separate existing result and a fresh call. Invalid n/entry limits are rejected by the preflight helper without huge allocation; work tests check an exact 1040-unit single-byte call, 1039/0 failure, shared-budget exhaustion, preflight budget preservation and fresh-call recovery.

Actual target results and commands are recorded below. Native runs both exhaustive and scale cases; JS/Wasm-GC run only the compact group. No apply/large-compression matrix, oracle build, upstream patch regeneration, historical probe or resource measurement is needed for this internal index change. Matching, diff, CLI and generation defaults remain later work.

## Actual verification (2026-11-06)

Toolchain: moon 0.1.20261102 (ea07287 2026-11-02), moonc v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102 (ea07287 2026-11-02), isolated installation. Native uses Windows MSVC; no global compiler installation was upgraded.

| Selection | Target | Result |
| --- | --- | --- |
| suffix_array_wbtest.mbt, all tests | native | 7/7 passed, including exhaustive and all three scale sizes |
| suffix_array_wbtest.mbt, suffix-compact* | JS | 5/5 passed in final selection |
| suffix_array_wbtest.mbt, suffix-compact* | Wasm-GC | 5/5 passed |
| limits_test.mbt + format_wbtest.mbt | native | 12/12 passed |

Native command: `moon test suffix_array_wbtest.mbt --target native --deny-warn`. Compact command: `moon test suffix_array_wbtest.mbt --filter 'suffix-compact*' --target js --deny-warn`, with wasm-gc substituted for the other target. Necessary regression: `moon test limits_test.mbt format_wbtest.mbt --target native --deny-warn`. There was also an earlier five-test JS development run before the added budget-preservation assertions; it is not counted as new cases.

moon info, moon fmt, moon fmt --check, native check --deny-warn, native build, and git diff --check passed. Root pkg.generated.mbti remains byte-for-byte unchanged. CI's existing native full suite discovers the seven new tests, and an explicit compact JS/Wasm-GC step checks nonzero results. Remote CI has not run.

No peak-memory or speed benchmark was run. Maximum actually sorted size was 16384 bytes; integer-limit preflight tests did not allocate arrays near those integer limits. Apply defaults, runtime and compression code were not changed, so their full matrices and historical measurements were not repeated. The remaining generation-wide quotas and defaults are reserved for Commit 11; this step does not deliver matching, diff or a CLI.
