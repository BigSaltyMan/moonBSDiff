# Preflight patch analysis (`analyze_patch`)

`analyze_patch` (added in **0.7.0**) runs bounded preflight forensics, stream-ratio calculation, seek profiling, minimum valid `Limits` derivation, and deterministic risk classification on a single BSDIFF40 patch — **without needing the old file or allocating a restored output buffer**.

It is available identically across **native, JS, and Wasm-GC** from the root package `BigSaltyMan/moonbsdiff`, and is also exposed by the native CLI via `moonbsdiff inspect --analyze`.

| Operation | Needs old file? | Allocates output? | Checks CRCs & controls? | Forensics, ratios, risk flags & `required_limits`? |
| --- | --- | --- | --- | --- |
| `inspect_header` | No | No | No (32-byte header only) | No |
| `inspect_deep` | No | No | Yes | No (counts only) |
| **`analyze_patch`** | **No** | **No** | **Yes** | **Yes** |
| `apply` / `apply_stream` | Yes | Yes (or streamed) | Yes | No |

See [inspect.md](inspect.md) for `inspect_header` and `inspect_deep`, [apply.md](apply.md) for patch application limits, and [manifest.md](manifest.md) for SHA-256 content identity and Ed25519 publisher authentication.

## Public MoonBit API (`BigSaltyMan/moonbsdiff`)

```moonbit
pub fn analyze_patch(Bytes, Limits) -> Result[PatchAnalysis, BsdiffError]
```

### Types

All analysis types derive `Eq` and `@debug.Debug`.

#### `PatchAnalysis`

Read-only struct returned by `analyze_patch`:

| Field | Type | Meaning |
| --- | --- | --- |
| `deep` | `DeepPatchInfo` | Exact `header`, `control_count`, `diff_bytes`, `extra_bytes`, and `expanded_bytes` matching `inspect_deep` |
| `ctrl_compressed_bytes` | `Int64` | Compressed Control stream length (`deep.header.control_length`) |
| `diff_compressed_bytes` | `Int64` | Compressed Diff stream length (`deep.header.diff_length`) |
| `extra_compressed_bytes` | `Int64` | Compressed Extra stream length (`deep.header.extra_length`) |
| `total_compressed_bytes` | `Int64` | `ctrl_compressed_bytes + diff_compressed_bytes + extra_compressed_bytes` (equals `patch_bytes - 32`) |
| `expansion_ratio_permille` | `Int64` | `floor(deep.expanded_bytes * 1000 / total_compressed_bytes)` |
| `diff_share_permille` | `Int64` | `floor(deep.diff_bytes * 1000 / deep.header.new_bytes)` |
| `extra_share_permille` | `Int64` | `floor(deep.extra_bytes * 1000 / deep.header.new_bytes)` |
| `patch_to_output_permille` | `Int64` | `floor(deep.header.patch_bytes * 1000 / deep.header.new_bytes)` |
| `negative_seek_count` | `Int64` | Number of control triples whose `seek_offset` (`z`) is strictly negative |
| `max_abs_seek` | `Int64` | Maximum saturating `|z|` across all control triples (`Int64::min_value` saturates to `9223372036854775807L`) |
| `required_limits` | `Limits` | Tightest valid `Limits` derived from this patch for `inspect_deep` / `analyze_patch` |
| `risk_level` | `RiskLevel` | Highest severity across `risk_flags` (`Low` when `risk_flags` is empty) |
| `risk_flags` | `ReadOnlyArray[PatchRiskFlag]` | Deterministic list of triggered risk findings |
| `sample_controls` | `ReadOnlyArray[ControlSample]` | First **64** decoded control triples (capped at `64` entries regardless of `control_count`) |

#### `ControlSample`

```moonbit
pub(all) struct ControlSample {
  index : Int64
  add_bytes : Int64
  extra_bytes : Int64
  seek_offset : Int64
}
```

Records zero-based control index and the decoded BSDIFF40 `(x, y, z)` triple (`add_bytes = x`, `extra_bytes = y`, `seek_offset = z`).

#### `RiskLevel` and `PatchRiskFlag`

```moonbit
pub(all) enum RiskLevel {
  Low
  Elevated
  High
}

pub(all) struct PatchRiskFlag {
  code : String
  severity : RiskLevel
  detail : String
}
```

## Overflow-safe permille math

All four `*_permille` ratios are computed in exact integer arithmetic (`floor(numerator * 1000 / denominator)`) without floating-point operations, guaranteeing bit-identical results across native, JS, and Wasm-GC:

- Whenever `numerator <= 0` or `denominator <= 0` (for example, an empty `0`-byte output or `0` expanded bytes), the ratio is `0L`.
- Large values split `numerator = q * denominator + r` and use overflow-free binary scaling for `(r * 1000) / denominator` when `r > Int64::max / 1000`, saturating at `9223372036854775807L` (`Int64::max`) if the quotient would exceed `Int64`.
- `1000` permille equals `1.0x` (`100%`); `20_000` permille equals `20.0x`; `100_000` permille equals `100.0x`.

## Deterministic risk flags

`analyze_patch` evaluates five deterministic heuristics in fixed order. `risk_level` is the maximum severity among all emitted flags (`High > Elevated > Low`), or `Low` if none fire:

| `code` | `severity` | Exact trigger condition | Interpretation |
| --- | --- | --- | --- |
| `HIGH_EXPANSION_RATIO` | `High` | `expansion_ratio_permille >= 100_000` (`>= 100x`) **and** `expanded_bytes >= 65_536` | Extreme bzip2 amplification; typical decompression-bomb profile |
| `HIGH_EXPANSION_RATIO` | `Elevated` | Otherwise, `expansion_ratio_permille >= 20_000` (`>= 20x`) **and** `expanded_bytes >= 16_384` | Notable bzip2 amplification worth review under constrained limits |
| `PATCH_LARGER_THAN_OUTPUT` | `Elevated` | `new_bytes > 0` **and** `patch_bytes >= new_bytes` | Patch file is at least as large as the target output (common for tiny files; consider full-file delivery) |
| `HIGH_EXTRA_RATIO` | `Elevated` | `new_bytes >= 256` **and** `extra_share_permille >= 850` (`>= 85%`) | Extra stream supplies most output verbatim rather than reusing bytes from the old file |
| `EXCESSIVE_CONTROL_DENSITY` | `High` | `control_count >= 1024` **and** `new_bytes > 0` **and** `control_count > new_bytes / 16` | Extremely fragmented control stream (> 1 control per 16 output bytes) |
| `EXCESSIVE_CONTROL_DENSITY` | `Elevated` | Otherwise, `control_count >= 256` **and** `new_bytes > 0` **and** `control_count > new_bytes / 64` | High control density (> 1 control per 64 output bytes) |
| `ZERO_OUTPUT_NONTRIVIAL_PATCH` | `Elevated` | `new_bytes == 0` **and** `(control_count > 0 \|\| expanded_bytes > 0 \|\| patch_bytes > 74)` | Non-trivial work or oversized container declared for a zero-byte target (canonical empty BSDIFF40 patch is 74 bytes: 32-byte header + three 14-byte empty bzip2 streams) |

## `required_limits` derivation

`PatchAnalysis.required_limits` is constructed from `Limits::for_apply()` by tightening all five patch-observable fields to the exact minimum valid positive limit (`max(1L, value)`, since `Limits::validate()` rejects zero):

| `Limits` field | Derived value in `required_limits` |
| --- | --- |
| `max_old_bytes` | `Limits::for_apply().max_old_bytes` (`1048576L`; not declared by BSDIFF40) |
| `max_new_bytes` | `max(1L, header.new_bytes)` |
| `max_patch_bytes` | `max(1L, header.patch_bytes)` |
| `max_output_bytes` | `max(1L, header.new_bytes)` |
| `max_decompressed_bytes` | `max(1L, deep.expanded_bytes)` |
| `max_control_instructions` | `max(1L, deep.control_count)` |
| `max_sort_work` | `Limits::for_apply().max_sort_work` (`1L`) |
| `max_match_work` | `Limits::for_apply().max_match_work` (`1L`) |

Guaranteed round-trip properties (verified in `analyze_test.mbt` across healthy, fast-path, empty, high-expansion, and dense-control patches):

1. `analysis.required_limits.validate() == Ok(())`.
2. `inspect_deep(patch, analysis.required_limits) == Ok(analysis.deep)`.
3. `analyze_patch(patch, analysis.required_limits) == Ok(analysis)`.
4. Reducing any of `max_patch_bytes`, `max_new_bytes`, `max_output_bytes`, `max_decompressed_bytes`, or `max_control_instructions` by `1` (whenever `> 1`) fails closed with `ResourceLimitExceeded`.

Because BSDIFF40 headers do not record the old file length, callers reusing `required_limits` for `apply` must still set `max_old_bytes` to match their expected old file (or verify both old and new identities via a signed manifest).

## Fail-closed decompression bomb preflight

`analyze_patch` shares the exact header parser, checked cursor arithmetic, 4096-byte compressed pull chunks, shared `@bounded.Budget` across all three bzip2 streams, per-stream caps (`control_cap = min(Int32::max, max_control_instructions * 24)`, `output_cap = new_size`), and verified-EOF trailing-data/CRC checks used by `inspect_deep`.

- **Tight-budget rejection**: `StreamReader` (`internal/bzip2/stream.mbt`) meters RLE1/BWT block output against the shared `Budget` *before* inverse-BWT allocation. If a BWT or RLE decompression bomb exceeds `max_patch_bytes`, `max_new_bytes`, `max_output_bytes`, `max_decompressed_bytes`, or `max_control_instructions` (or fails bzip2 block/combined CRC, truncation, or unconsumed-byte checks), `analyze_patch` aborts immediately during bounded streaming with zero emitted bytes and returns the **exact same `Err(BsdiffError)`** as `inspect_deep` (and blocks identically in `apply_stream`) across native, JS, and Wasm-GC.
- **Two-stage ingestion workflow**: A release server or security gate can inspect untrusted patches with an explicit upper bound, reject anything failing `analyze_patch`, and inspect `risk_level` / `risk_flags` / `required_limits` before distributing patches to memory-constrained clients.
- **Security boundary**: `analyze_patch` verifies BSDIFF40 structure and decompression resource usage only. It does **not** authenticate the publisher or verify old/new file content; pair with detached Ed25519 manifests ([manifest.md](manifest.md)) or signed release catalogs ([catalog.md](catalog.md)).

## MoonBit usage example

In `moon.pkg`:

```moonbit
import {
  "BigSaltyMan/moonbsdiff" @moonbsdiff,
  "moonbitlang/core/debug" @debug,
}
```

In MoonBit source (runs identically on native, JS, and Wasm-GC):

```moonbit
fn preflight_patch(patch : Bytes) -> Result[@moonbsdiff.PatchAnalysis, String] {
  let limits = @moonbsdiff.Limits::for_apply()
  match @moonbsdiff.analyze_patch(patch, limits) {
    Err(err) => Err("rejected patch: " + @debug.to_string(err))
    Ok(analysis) => {
      if analysis.risk_level == @moonbsdiff.High {
        return Err("high-risk patch quarantined: " + @debug.to_string(analysis.risk_flags))
      }
      Ok(analysis)
    }
  }
}
```

## CLI (`moonbsdiff inspect --analyze`)

The native CLI exposes `analyze_patch` through `inspect --analyze` (mutually exclusive with `--deep`):

```sh
moonbsdiff inspect --analyze update.patch
moonbsdiff inspect --analyze --json update.patch
moonbsdiff inspect --analyze --max-patch-bytes 256KiB --max-output-bytes 2MiB --max-expanded-bytes 4MiB --max-controls 32768 update.patch
```

- Sets `max_new_bytes = max_output_bytes` from the effective CLI apply limits (`128 KiB` patch, `1 MiB` output, `2 MiB` expanded, `16384` controls by default).
- `--json` emits Schema 1 JSON with `"validation": "analyze"`, `"risk_level"` (`"low"`, `"elevated"`, `"high"`), `"header"`, `"deep"`, `"ratios"`, `"seeks"`, `"risk_flags"`, `"required_limits"`, and `"sample_controls"`. All 64-bit counts, ratios, offsets, and limits are lossless decimal strings.
- Exit codes follow standard CLI conventions: `0` on success, `1` on read/format/CRC/limit failure (empty stdout, diagnostic on stderr), and `2` on invalid arguments.

Related docs: [inspect.md](inspect.md), [apply.md](apply.md), [format.md](format.md), [manifest.md](manifest.md), [catalog.md](catalog.md).
