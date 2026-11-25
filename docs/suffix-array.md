# Binary suffix-array index

## Route and source relationship

In **0.7.0**, the internal `build_suffix_array` (and `build_suffix_array_view`) in `suffix_array.mbt` was upgraded from the earlier `O(n log n)` prefix-doubling builder to an original, pure-MoonBit linear-time **`O(n)` SA-IS (Suffix Array Induced Sorting)** implementation. The upgrade preserves the exact BSDIFF40 suffix order contract and bounded `SortBudget` accounting without changing any public signature in `pkg.generated.mbti`.

BSDiff 4.3 `bsdiff.c::qsufsort` and `split` were reviewed from the existing, SHA-256-verified local source (`fc0a6e634ef77dcf14bf36c7b6d1e57ba1ac5c4809073dfaacb3b5f7ab277eb7`). Its suffix positions and leading empty-suffix contract remain the reference. No `qsufsort` code is translated and no code from another suffix-array or SA-IS implementation was copied. BSDiff's original Colin Percival copyright and complete BSD notice remain in [upstream.md](upstream.md) and `tools/oracle/BSDIFF-LICENSE.txt`; the MoonBit implementation is under the repository BSD-2-Clause license.

## Contract and invariants

For an input slice `data` of `n` bytes (`N = n + 1`), `build_suffix_array` / `build_suffix_array_view` returns a freshly allocated `sa : Array[Int32]` of length `N` containing every position `0..n` exactly once in strict unsigned-byte lexicographic order:

- `sa[0] == n` is the empty sentinel suffix and always comes first.
- `data[sa[i]:] < data[sa[i + 1]:]` strictly for every `0 <= i < n`.
- A shorter prefix suffix precedes a longer suffix sharing that prefix.
- `0x00` and `0xff` are ordinary unsigned input bytes (`0..255`). The appended sentinel symbol `0` is strictly smaller than every remapped input byte (`1..sigma`), never colliding with `0x00`.
- Input bytes are never mutated; non-zero-offset `BytesView` slices produce the exact same suffix array as standalone copied `Bytes`. Returned arrays are caller-owned and never aliased across calls.

### Linear-time SA-IS algorithm

1. **Preflight (`suffix_sizes`)**: Pure validation without allocation. Checks `max_entries` in `1..2147483647` (`InvalidConfiguration`, field `"suffix_entries"`) and `n` in `0..2147483646` (`IntegerOverflow`, field `"suffix_length"`), computes `N = n + 1` in `Int64`, enforces `N <= max_entries` (`ResourceLimitExceeded`, field `"suffix_entries"`), and narrows `(N, B)` to `Int32` where `B = max(N, 257)`.
2. **Empty input (`n == 0`)**: Reserves `1` work unit and returns `[0]` without allocating sorting buffers.
3. **Top-level alphabet compaction and all-distinct fast path**:
   - Counts byte frequencies into `raw_counts[0..255]`, remaps occurring bytes in ascending unsigned order to dense positive symbols `1..sigma` (`remap`), and initializes `bkt_size` with `[1]` for the sentinel symbol `0` so the compacted alphabet has size `k = sigma + 1` (`2 <= k <= 257`).
   - **Unique-byte fast path (`sigma == n`)**: When every input byte is distinct (for example, any 1-byte input or a byte permutation), first bytes alone determine the complete suffix order. The builder places `sa[0] = n` and `sa[remap[data[i]]] = i` directly and returns without entering `sais_rec`.
   - Otherwise populates `s` of length `N` with `s[i] = remap[data[i]]` for `0 <= i < n` and `s[n] = 0`, then invokes `sais_rec(s, N, sigma + 1, Some(bkt_size), budget)`.
4. **Recursive SA-IS core (`sais_rec`)**:
   - **Precondition**: `m >= 2`, `k >= 2`, `s[m - 1] == 0` is the unique smallest sentinel, and `1 <= s[i] < k` for all `0 <= i < m - 1`.
   - **S/L classification and LMS collection**: Scans right-to-left marking `is_s[m - 1] = true` (sentinel is S-type), `is_s[m - 2] = false` (since `s[m - 2] >= 1 > 0`), and `is_s[idx] = (s[idx] < s[idx + 1]) || (s[idx] == s[idx + 1] && is_s[idx + 1])` for `idx` down to `0`. A left-to-right scan then collects all Leftmost S-type (LMS) positions (`pos > 0 && is_s[pos] && !is_s[pos - 1]`) into `lms_pos`. Because no two adjacent indices can both be LMS, `1 <= lms_count <= floor(m / 2)`.
   - **First induced sort**: Scatters `lms_pos` into bucket tails (`bucket_tails`) and calls `induce_sort`:
     - Left-to-right pass from `bucket_heads` induces all L-type suffixes (`pos > 0 && !is_s[pos - 1]`).
     - Right-to-left pass from `bucket_tails` induces all S-type suffixes (`pos > 0 && is_s[pos - 1]`).
   - **Single-LMS early return (`lms_count == 1`)**: When only the sentinel is LMS (such as all-same inputs like `b"AA"` or `b"\xff" * 16384`, or monotonically descending inputs), the first induced sort already yields the exact final suffix array and returns `Ok(sa)` immediately.
   - **LMS substring naming**: Allocates `lms_names` of length `half = (m - 1) / 2 + 1` indexed by `pos / 2` (collision-free since LMS positions are never adjacent). Scans `sa[1..<m]` in induced order, compares consecutive LMS substrings using `lms_substrings_equal` (matching both symbol `s` and type `is_s` up to the next LMS boundary; sentinel `m - 1` matches only itself), and assigns dense names `0..k1 - 1` (`k1 = name + 1`).
   - **LMS suffix ordering**:
     - If `k1 == lms_count`, every LMS substring is unique and `sa` already holds the exact LMS order; `sorted_lms` is extracted directly in one scan.
     - Otherwise builds the reduced string `s1` of length `lms_count` (`s1[j] = lms_names[lms_pos[j] / 2]`, with unique smallest sentinel `s1[lms_count - 1] == 0`), recursively calls `sais_rec(s1, lms_count, k1, None, budget)`, and maps `sa1` back to original positions `lms_pos[sa1[j]]`.
   - **Final induced sort**: Resets `sa` to `-1`, scatters `sorted_lms` right-to-left into bucket tails (preserving their exact sorted order within every bucket), and runs `induce_sort` to produce the complete suffix array.

## Bounds, memory, and `SortBudget` accounting

All index bounds and work reservations use `Int64` arithmetic after `suffix_sizes` proves `N <= 2147483647`. Bucket head and tail cursors stay strictly within `0..<m` because `sum(bkt_size[0..<k]) == m` at every level.

An explicit internal `SortBudget` carries remaining `Int64` logical work units across all passes and recursive levels, driven by `Limits.max_sort_work` in `diff`, `diff_with_options`, and `DiffIndex::build` (see [generation-resources.md](generation-resources.md) and [diff-index.md](diff-index.md)). A negative budget (`sorting_budget`) or negative reservation (`SortBudget::reserve`) returns `InvalidConfiguration` at stage `Sorting`; zero remaining is exhausted, never unlimited. Failed reservations return `ResourceLimitExceeded` (stage `Sorting`, field `"sort_remaining"`, `value = requested`, `limit = remaining`) without deducting the failed request; completed stages remain charged. Preflight rejections in `suffix_sizes` consume zero budget.

### Stage-by-stage work reservations

| Stage | Condition | Logical work units (`Int64`) |
| --- | --- | --- |
| Empty input | `n == 0` (`N = 1`) | `1` |
| Top-level initialization | `n >= 1`, `B = max(N, 257)` | `4*N + B` |
| Alphabet compaction + scatter / mapping | `n >= 1` | `2*N + 256` |
| Recursive level setup | `precomputed_bkt_size == None` | `3*m + 2*k` |
| S/L classification + LMS collection | each `sais_rec` level | `2*m` |
| First induced sort | each `sais_rec` level | `2*m + 3*k + lms_count` |
| LMS substring naming | `lms_count > 1`, `half = (m - 1)/2 + 1` | `2*m + lms_count + half` |
| LMS ordering (unique names) | `k1 == lms_count` | `m + lms_count` |
| LMS ordering (recursive) | `k1 < lms_count` | `2*lms_count` + child `sais_rec` + `2*lms_count` |
| Final induced sort | `lms_count > 1` | `3*m + 3*k + lms_count` |

These are defined algorithmic visit charges, not machine-instruction counts or wall-clock limits. Caller-selected entry limits (`max_old_bytes`) and practical work budgets (`max_sort_work`) remain necessary; logical array sizes do not cap allocator overhead, GC retention, or process RSS.

### Exact work boundaries and linear scaling

Because every recursive level reduces problem size by at least half (`lms_count <= floor(m / 2)` and `k1 <= lms_count`), both total running time and total `SortBudget` consumption form a convergent geometric series:

- **Time complexity**: strictly **`O(n)`** across all input shapes (including repeated, periodic, alternating, Fibonacci, and Thue-Morse inputs that trigger multi-level recursion).
- **Auxiliary space**: **`O(n)`** (top-level `s`, `sa`, `is_s`, `bkt_size`/`bkt`, and geometric recursive workspaces totaling `< 2N` elements).
- **Exact small-fixture boundaries** (verified in `suffix_array_wbtest.mbt` and `diff_resources_wbtest.mbt`):
  - `b""` (`N = 1`): **1** unit.
  - `b"A"` (`N = 2`, `B = 257`, unique-byte fast path): **525 exact / 524 one-short** (`4*2 + 257 = 265` init + `2*2 + 256 = 260` compaction & scatter; one-short fails requesting `260` with `259` remaining).
  - `b"AA"` (`N = 3`, `B = 257`, `k = 2`, `lms_count = 1` early return): **550 exact / 549 one-short** (`4*3 + 257 = 269` init + `2*3 + 256 = 262` compaction + `2*3 = 6` classify/collect + `2*3 + 3*2 + 1 = 13` first induced sort; one-short fails requesting `13` with `12` remaining).
- **Measured linear scaling bounds** (enforced by `suffix-sais-linear-work-and-recursive-budget-exhaustion`):
  - All-same inputs hit `lms_count == 1` and stay below **`13*n`** units (~`11*n`).
  - Periodic (period-7), alternating (`0x00 0xff`, recursive), and LCG random inputs all stay below **`35*n`** units across 1 KiB, 4 KiB, and 16 KiB.
  - 64 KiB period-7 input uses fewer than **`2,500,000`** units, fitting comfortably inside the default `Limits::for_diff().max_sort_work` (`8,388,608`).

### Measured SA-IS vs prefix-doubling at 256 KiB and 1 MiB

Interleaved native `--release` measurements (locked 0.10.19 Windows MSVC, 1 warmup + 5 runs) comparing 0.7.0 SA-IS directly against 0.6.0 prefix-doubling and the recorded 0.5.4 baseline (`testdata/release/0.5.4.json`):

| Case | 0.5.4 `sort_work` | 0.7.0 `sort_work` (`diff` / full SA) | `sort_work` vs 0.5.4 | 0.6.0 -> 0.7.0 SA median (Win MSVC) | Patch == 0.5.4 |
| --- | ---: | ---: | --- | --- | --- |
| `256k-sparse` | 5,896,636 | 5,935,466 / 6,926,208 | 1.01x / 1.17x | 13.61 -> 17.66 ms (0.77x) | Yes (188 B) |
| `256k-periodic` | 21,758,538 | **4,849,999** / 4,849,999 | **4.49x less (-77.7%)** | **33.32 -> 7.69 ms (4.33x faster)** | Yes (165 B) |
| `256k-random` | 5,896,636 | 6,926,208 / 6,926,208 | 1.17x | 13.95 -> 17.74 ms (0.79x) | Yes (263,849 B) |
| `1m-sparse` | 23,200,464 | 23,738,932 / 27,689,504 | 1.02x / 1.19x | 70.78 -> 113.67 ms (0.62x) | Yes (197 B) |
| `1m-periodic` | 95,421,038 | **19,398,999** / 19,398,999 | **4.92x less (-79.7%)** | **182.53 -> 30.19 ms (6.05x faster)** | Yes (168 B) |
| `1m-random` | 23,200,464 | 27,689,504 / 27,689,504 | 1.19x | 65.25 -> 82.22 ms (0.79x) | Yes (1,053,978 B) |

- **Exact parity**: Element-for-element `sa_sais[i] == sa_pd[i]` holds across all `n + 1` entries on all 6 inputs, and generated `patch_bytes` / `patch_sha256` match 0.5.4/0.6.0 byte-for-byte.
- **Confirmed linear scaling**: The 1 MiB / 256 KiB `sort_work` ratio is **`4.000x`** on periodic (`19,398,999 / 4,849,999`, ~`18.5n`) and **`3.998x`** on random (`27,689,504 / 6,926,208`, ~`26.4n`), versus `4.385x` (~`91n` at 1 MiB) for prefix-doubling on periodic inputs.
- **Workload profile**: On `sparse`, `diff` trims the `n / 7` common prefix before suffix sorting. On high-entropy random bytes, prefix-doubling exits after ~3 doubling rounds so SA-IS uses ~17–19% more `sort_work` (still only ~13.2% of the `200 * (n + 1)` scale quota), whereas on repetitive/periodic inputs SA-IS cuts `sort_work` by **4.49x–4.92x** and speeds up SA construction by **4.33x–6.05x**.

### Historical prefix-doubling baseline

Prior to 0.7.0, `build_suffix_array` used an `O(n log n)` prefix-doubling algorithm (initial length-1 counting sort `3N + 257` plus `4N + step + 2K` per doubling round; earlier Commit 11 used two counting passes per round at `5N + 4K`). Its historical single-byte / two-byte exact figures were `528 / 552` (and earlier `1303` in Commit 11 and `1040` in Commit 7). The suffix ordering output contract is completely unchanged across all generations.

## Independent verification

`suffix_array_wbtest.mbt` verifies SA-IS against an independent test-only insertion-sort oracle (`naive_suffix_less` and `naive_suffix_array`) that compares raw input bytes and explicit lengths directly without ranks, buckets, or induced sorting, plus a full structural checker (`suffix_test_complete`) verifying length `N`, valid range, permutation completeness, `sa[0] == n`, and strict adjacent lexicographic order:

- **Manual and binary fixtures** (`suffix-compact-manual-complete-vectors`, `suffix-compact-binary-and-prefixes`, `suffix-compact-seeded-random`, `suffix-compact-state-isolation`): empty, `0xff`, `"banana"`, `00 ff 00`, `"AAAA"`, `"aba"`, ascending/descending `0..255`, 128-byte NUL runs, period-3 `00/ff`, long common prefixes, 64 LCG-random lengths (`0..63`, seed `20261106 + i`), and caller mutation isolation.
- **Exhaustive and scale tests** (`suffix-native-exhaustive`, `suffix-native-scale-and-growth`): all 3,280 strings of lengths `0..7` over `{0x00, 0x01, 0xff}`, plus 1,024 / 4,096 / 16,384-byte all-`0xff`, period-7, and LCG-random inputs.
- **0.7.0 SA-IS edge cases and views** (`suffix-sais-edge-cases-and-views`): all 256 single-byte values, all 2-byte boundary pairs (`00/00`, `00/ff`, `ff/00`, `ff/ff`, `00/01`, `fe/ff`), full 256-byte alphabet repeated forward and backward, and non-zero-offset `BytesView` slice parity.
- **0.7.0 multi-level recursion stress** (`suffix-sais-multilevel-recursion-and-periodic`): `babababa`, alternating `ab`/`ba`/`00 ff`/`ff 00`, repeated `mmiissiissiippii`/`abacabad`/`aaabaaac`, Fibonacci words `F_0..F_14`, and Thue-Morse words `T_0..T_10`.
- **0.7.0 recursive budget exhaustion and linear scaling** (`suffix-compact-preflight-and-work-budget`, `suffix-sais-linear-work-and-recursive-budget-exhaustion`): exact/one-short checks for `b"A"` (`525/524`) and `b"AA"` (`550/549`), stepping downward across every reservation checkpoint of 128-byte Thue-Morse `T_7` (confirming `>= 8` distinct fail-closed reservation boundaries across recursive levels with nonnegative remaining budget), and linear `< 13n` / `< 35n` work bounds through 64 KiB.

Related docs: [generation-resources.md](generation-resources.md), [matching.md](matching.md), [diff-index.md](diff-index.md), [upstream.md](upstream.md).
