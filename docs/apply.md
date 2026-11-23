# Applying BSDIFF40 patches

`apply(old_bytes : Bytes, patch_bytes : Bytes, limits : Limits) -> Result[Bytes, BsdiffError]` is a pure in-memory operation. Explicit Limits are required by apply; use Limits::for_apply() for the application defaults, including a 128 KiB patch cap. It validates configuration and actual old/patch sizes, checks the header, and requires restored size to fit both max_new_bytes and max_output_bytes (each bounded to Int indexing by Limits). It creates one decompression budget for the three intervals. Control output is capped at min(Int maximum, 24 * max_control_instructions), using division before multiplication to avoid overflow. Diff and extra output caps each equal the validated restored size. A zero internal cap accepts only empty decoded output. These controls do not provide an overall peak-memory or wall-clock guarantee. Application defaults and measurement evidence are in [apply-acceptance.md](apply-acceptance.md).

Three strict bzip2 streams are decoded with the existing bounded adapter, correct block labels and absolute starting offsets. Aligned control length and finite instruction count are checked before allocating the output array. The decoder reads each compressed interval as a read-only view of the original patch. The full-buffer implementation still keeps the decoded blocks and output in memory and copies the final output array to Bytes. Limits do not cap whole-process memory.

For each (x,y,z), x/y must be nonnegative. Output and source availability are checked with remaining lengths before narrowing. Old cursor plus x and then plus z use checked Int64 additions. Per-byte old access occurs only when its Int64 position is in [0, old length); outside positions contribute zero. This also handles Int64 minimum without negating it. Byte sums are explicitly reduced modulo 256. Zero-output instructions are allowed before the output is complete; each consumes one finite control triple. Once output is complete, any remaining control triple is rejected as unconsumed, including for empty targets. All three compressed streams must still be valid for an empty target.

Success requires exactly the declared output size and full consumption of control, diff and extra data. Errors return no partial bytes, and neither input is modified. Each call creates a fresh budget; failures cannot reduce the next call's budget.

## Location and error conventions

Compressed decoder errors retain patch-file absolute offsets (when available). Header errors retain field offsets. Decoded instruction errors have offset None and field `control_decoded_byte[N].x`, `.y`, `.old_plus_x`, or `.old_plus_z`: N is a decoded control byte position, not a compressed patch offset. Other decoded errors use fields such as control_decoded_alignment, diff_decoded_consumption, unconsumed_extra and output_size; offsets are None. Kind/stage/block remain structured. Negative control counts are InvalidField, missing data/alignment are TruncatedData, output overrun is OutputOutOfBounds, arithmetic overflow is IntegerOverflow, unused data is InvalidField, and limits are ResourceLimitExceeded. Per-block caps may reject redundant decoded bytes before a later consumption check.

## Reproduction and evidence

`python scripts/check_apply.py` verifies embedded bytes against all 13 unchanged upstream fixtures and the independent Python bz2 manual cases. `--generate` explicitly regenerates only the compact apply embedding and manual manifest; it does not rebuild the oracle or regenerate upstream patches. Manual controls and expected results are reviewable in the script and testdata/apply/manifest.json. Run apply tests with `moon test apply_test.mbt apply_vectors_test.mbt --target native --deny-warn` (also js or wasm-gc). The README memory example is an executed public API test.

This document originally recorded the application stage. Generation, native CLI and both interoperability directions are now implemented; see [generation](generation.md), [CLI](cli.md) and [compatibility](compatibility.md) for their separate evidence. BSDIFF40 has no built-in old-file identity hash. Wrong old bytes can produce apparently successful but incorrect output, so applications must verify expected input/output hashes externally.

Application-stage coverage, exact resource boundaries and final three-target results: [stage acceptance](apply-acceptance.md). Reproduce the new compact fixtures with scripts/check_apply_boundaries.py --generate followed by moon fmt. This also reproduces the five resource-test byte literals from independent Python recipes.

## Cross-target streaming application (`apply_stream`, Unreleased)

`BigSaltyMan/moonbsdiff` exposes a cross-target streaming application entry point
that works identically on Native, JavaScript, and Wasm-GC without buffering the
whole old input, patch, or restored output in memory:

```moonbit
pub(all) enum StreamApplyStage {
  HeaderVerified(PatchInfo)
  Restoring
  Validating
}

pub(all) enum StreamApplyError[E] {
  Bsdiff(BsdiffError)
  Io(E)
}

pub fn[E] apply_stream(
  old_size : Int64,
  patch_size : Int64,
  limits : Limits,
  read_old_at~ : (Int64, Int32) -> Result[Bytes, E],
  read_patch_at~ : (Int64, Int32) -> Result[Bytes, E],
  write_output~ : (Bytes) -> Result[Unit, E],
  on_stage? : (StreamApplyStage) -> Result[Unit, E],
  checkpoint? : () -> Result[Unit, E],
) -> Result[DeepPatchInfo, StreamApplyError[E]]
```

Behavior and guarantees:

- **Preflight**: validates `limits`, non-negative `old_size <= max_old_bytes`,
  and non-negative `patch_size <= max_patch_bytes`. Reads up to the 32-byte
  header prefix via `read_patch_at` and validates it with
  `inspect_header_prefix`, then checks `info.new_bytes` against both
  `max_output_bytes` and `max_new_bytes` before emitting `HeaderVerified(info)`
  and opening the three streams.
- **Bounded chunked IO (`<= 4096` bytes)**: refills the three compressed bzip2
  stream readers (`control`, `diff`, `extra`), reads `old` byte spans via
  `read_old_at`, and emits restored chunks via `write_output` in chunks of at
  most `4096` bytes. Each range read (`read_old_at`, `read_patch_at`) must
  return `1..requested` bytes on `Ok`; returning `0` bytes fails with
  `Bsdiff(TruncatedData)` and returning more than requested fails with
  `Bsdiff(InvalidField)`. Outside-old cursor positions contribute zero and byte
  sums wrap modulo 256, matching `apply`.
- **Stage and checkpoint hooks**: calls optional `on_stage` at
  `HeaderVerified(PatchInfo)`, `Restoring`, and `Validating`, and optional
  `checkpoint` before reading each control triple, diff/extra chunk, and final
  stream validation. Any callback `Err(e)` stops immediately with `Err(Io(e))`.
- **Strict completion**: enforces shared `max_decompressed_bytes`,
  `max_control_instructions`, block/combined CRCs, end markers, and exact
  consumption of `control`, `diff`, and `extra` intervals, returning
  `Ok(DeepPatchInfo)` on success.
- **No library file IO**: `BigSaltyMan/moonbsdiff` remains pure and performs no
  host filesystem calls on Native, JS, or Wasm-GC; callers supply the range and
  output callbacks. The native CLI (`cmd/main`) streaming executor uses
  `apply_stream` directly over OS file-handle callbacks.

### Structured-error nuances compared to in-memory `apply`

`apply_stream` enforces the same BSDIFF40 validity and resource contracts as
in-memory `apply`, with a few intentional structured-error differences driven by
incremental decoding: control-triple validation reports `diff_length`,
`extra_length`, `old_plus_x`, and `old_plus_z` (rather than in-memory
`control_decoded_byte[N].*`); an empty control stream when `new_bytes > 0`
reports `TruncatedData` at `Control` (`control_triple_bytes`) rather than
`Output` (`output_size`); any trailing decoded bytes after
`produced == new_bytes` report `InvalidField` with `unconsumed_control`,
`unconsumed_diff`, or `unconsumed_extra`; `Int64` cursor overflow checks
(`oldpos + x`, `oldend + z`) run before reading that instruction's `diff` and
`extra` chunks; and multi-chunk `diff`/`extra` truncation reports cumulative
expected/consumed byte counts matching in-memory `apply`.
