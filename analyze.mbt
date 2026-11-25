///|
const ANALYZE_INT64_MAX : Int64 = 9223372036854775807L

///|
const ANALYZE_INT64_MIN : Int64 = -9223372036854775807L - 1L

///|
const MAX_SAMPLE_CONTROLS : Int32 = 64

///|
/// One decoded BSDIFF40 control triple sampled during patch analysis.
#derive(Eq, Debug)
pub(all) struct ControlSample {
  index : Int64
  add_bytes : Int64
  extra_bytes : Int64
  seek_offset : Int64
}

///|
pub extend ControlSample with Eq::{equal, not_equal}

///|
pub extend ControlSample with @debug.Debug::{to_repr}

///|
/// Overall or per-flag preflight risk classification.
#derive(Eq, Debug)
pub(all) enum RiskLevel {
  Low
  Elevated
  High
}

///|
pub extend RiskLevel with Eq::{equal, not_equal}

///|
pub extend RiskLevel with @debug.Debug::{to_repr}

///|
/// A deterministic preflight risk finding raised by `analyze_patch`.
#derive(Eq, Debug)
pub(all) struct PatchRiskFlag {
  code : String
  severity : RiskLevel
  detail : String
}

///|
pub extend PatchRiskFlag with Eq::{equal, not_equal}

///|
pub extend PatchRiskFlag with @debug.Debug::{to_repr}

///|
/// Structured forensics, ratios, minimum valid limits, and preflight risk report
/// for a single verified BSDIFF40 patch.
#derive(Eq, Debug)
pub struct PatchAnalysis {
  deep : DeepPatchInfo
  ctrl_compressed_bytes : Int64
  diff_compressed_bytes : Int64
  extra_compressed_bytes : Int64
  total_compressed_bytes : Int64
  expansion_ratio_permille : Int64
  diff_share_permille : Int64
  extra_share_permille : Int64
  patch_to_output_permille : Int64
  negative_seek_count : Int64
  max_abs_seek : Int64
  required_limits : Limits
  risk_level : RiskLevel
  risk_flags : ReadOnlyArray[PatchRiskFlag]
  sample_controls : ReadOnlyArray[ControlSample]
}

///|
pub extend PatchAnalysis with Eq::{equal, not_equal}

///|
pub extend PatchAnalysis with @debug.Debug::{to_repr}

///|
fn abs_int64_saturating(value : Int64) -> Int64 {
  if value == ANALYZE_INT64_MIN {
    ANALYZE_INT64_MAX
  } else if value < 0L {
    -value
  } else {
    value
  }
}

///|
fn min_positive_limit(value : Int64) -> Int64 {
  if value < 1L {
    1L
  } else {
    value
  }
}

///|
// Exact floor(numerator * 1000 / denominator) for non-negative Int64 values,
// saturating at Int64::max_value on quotient overflow and returning 0 when
// either input is non-positive.
fn ratio_permille(numerator : Int64, denominator : Int64) -> Int64 {
  if numerator <= 0L || denominator <= 0L {
    return 0L
  }
  let q = numerator / denominator
  let r = numerator % denominator
  let max_q = ANALYZE_INT64_MAX / 1000L
  if q > max_q {
    return ANALYZE_INT64_MAX
  }
  let hi = q * 1000L
  let lo = if r <= max_q {
    r * 1000L / denominator
  } else {
    // Exact binary scaling of (r * 1000) / denominator without 64-bit overflow.
    let mut acc_q = 0L
    let mut acc_r = 0L
    let mut cur_q = 0L
    let mut cur_r = r
    let mut mult = 1000
    while mult > 0 {
      if (mult & 1) != 0 {
        acc_q = acc_q + cur_q
        if acc_r >= denominator - cur_r {
          acc_r = acc_r - (denominator - cur_r)
          acc_q = acc_q + 1L
        } else {
          acc_r = acc_r + cur_r
        }
      }
      mult = mult >> 1
      if mult > 0 {
        cur_q = cur_q + cur_q
        if cur_r >= denominator - cur_r {
          cur_r = cur_r - (denominator - cur_r)
          cur_q = cur_q + 1L
        } else {
          cur_r = cur_r + cur_r
        }
      }
    }
    acc_q
  }
  if hi > ANALYZE_INT64_MAX - lo {
    ANALYZE_INT64_MAX
  } else {
    hi + lo
  }
}

///|
fn max_risk_level(a : RiskLevel, b : RiskLevel) -> RiskLevel {
  match (a, b) {
    (High, _) | (_, High) => High
    (Elevated, _) | (_, Elevated) => Elevated
    _ => Low
  }
}

///|
fn evaluate_risk_flags(
  deep : DeepPatchInfo,
  total_compressed_bytes : Int64,
  expansion_ratio_permille : Int64,
  extra_share_permille : Int64,
  patch_to_output_permille : Int64,
) -> (RiskLevel, ReadOnlyArray[PatchRiskFlag]) {
  let flags : Array[PatchRiskFlag] = []
  let patch_bytes = deep.header.patch_bytes
  let new_bytes = deep.header.new_bytes
  let expanded_bytes = deep.expanded_bytes
  let control_count = deep.control_count
  if expansion_ratio_permille >= 100_000L && expanded_bytes >= 65536L {
    flags.push({
      code: "HIGH_EXPANSION_RATIO",
      severity: High,
      detail: "decompressed \{expanded_bytes} bytes from \{total_compressed_bytes} compressed bytes (\{expansion_ratio_permille} permille)",
    })
  } else if expansion_ratio_permille >= 20_000L && expanded_bytes >= 16384L {
    flags.push({
      code: "HIGH_EXPANSION_RATIO",
      severity: Elevated,
      detail: "decompressed \{expanded_bytes} bytes from \{total_compressed_bytes} compressed bytes (\{expansion_ratio_permille} permille)",
    })
  }
  if new_bytes > 0L && patch_bytes >= new_bytes {
    flags.push({
      code: "PATCH_LARGER_THAN_OUTPUT",
      severity: Elevated,
      detail: "patch size \{patch_bytes} bytes is >= output size \{new_bytes} bytes (\{patch_to_output_permille} permille)",
    })
  }
  if new_bytes >= 256L && extra_share_permille >= 850L {
    flags.push({
      code: "HIGH_EXTRA_RATIO",
      severity: Elevated,
      detail: "extra stream supplies \{deep.extra_bytes} of \{new_bytes} output bytes (\{extra_share_permille} permille)",
    })
  }
  if control_count >= 1024L && new_bytes > 0L && control_count > new_bytes / 16L {
    flags.push({
      code: "EXCESSIVE_CONTROL_DENSITY",
      severity: High,
      detail: "\{control_count} control instructions for \{new_bytes} output bytes",
    })
  } else if control_count >= 256L &&
    new_bytes > 0L &&
    control_count > new_bytes / 64L {
    flags.push({
      code: "EXCESSIVE_CONTROL_DENSITY",
      severity: Elevated,
      detail: "\{control_count} control instructions for \{new_bytes} output bytes",
    })
  }
  if new_bytes == 0L &&
    (control_count > 0L || expanded_bytes > 0L || patch_bytes > 74L) {
    flags.push({
      code: "ZERO_OUTPUT_NONTRIVIAL_PATCH",
      severity: Elevated,
      detail: "zero-byte output with \{patch_bytes}-byte patch (\{control_count} controls and \{expanded_bytes} decompressed bytes)",
    })
  }
  let mut level = Low
  for flag in flags {
    level = max_risk_level(level, flag.severity)
  }
  (level, ReadOnlyArray::makei(flags.length(), i => flags[i]))
}

///|
fn analyze_streams(
  patch : Bytes,
  ranges : PatchRanges,
  limits : Limits,
) -> PatchAnalysis raise InspectFault {
  let budget = @bounded.Budget::{
    remaining: limits.max_decompressed_bytes,
    emitted: 0L,
  }
  let control_cap = if limits.max_control_instructions > 2147483647L / 24L {
    2147483647
  } else {
    (limits.max_control_instructions * 24L).to_int()
  }
  let output_cap = ranges.new_size.to_int()
  let control = InspectStream::open(
    patch,
    ranges.control_start,
    ranges.control_end,
    control_cap,
    budget,
    Control,
  )
  let delta = InspectStream::open(
    patch,
    ranges.control_end,
    ranges.diff_end,
    output_cap,
    budget,
    Diff,
  )
  let extra = InspectStream::open(
    patch,
    ranges.diff_end,
    ranges.extra_end,
    output_cap,
    budget,
    Extra,
  )
  let mut control_count = 0L
  let mut diff_bytes = 0L
  let mut extra_bytes = 0L
  let mut oldpos = 0L
  let mut remaining = ranges.new_size
  let mut negative_seek_count = 0L
  let mut max_abs_seek = 0L
  let samples : Array[ControlSample] = []
  while remaining > 0L {
    if control_count >= limits.max_control_instructions {
      raise InspectionFailed(
        apply_error(
          ResourceLimitExceeded,
          Control,
          "max_control_instructions",
          Some(control_count + 1L),
          Some(limits.max_control_instructions),
        ),
      )
    }
    let triple = control.read(24)
    if triple.length() != 24 {
      raise InspectionFailed(
        apply_error(
          TruncatedData,
          Control,
          "control_triple_bytes",
          Some(triple.length().to_int64()),
          Some(24L),
        ),
      )
    }
    let x = inspect_or_raise(decode_int(triple, 0, Control))
    let y = inspect_or_raise(decode_int(triple, 8, Control))
    let z = inspect_or_raise(decode_int(triple, 16, Control))
    for (field, value) in [("x", x), ("y", y)] {
      if value < 0L {
        raise InspectionFailed(
          apply_error(InvalidField, Control, field, Some(value), None),
        )
      }
    }
    let control_index = control_count
    control_count += 1L
    inspect_output_length(x, remaining, "x")
    let oldend = inspect_or_raise(cursor_add(oldpos, x, "old_plus_x"))
    delta.consume(x)
    diff_bytes += x
    remaining -= x
    inspect_output_length(y, remaining, "y")
    extra.consume(y)
    extra_bytes += y
    remaining -= y
    oldpos = inspect_or_raise(cursor_add(oldend, z, "old_plus_z"))
    if z < 0L {
      negative_seek_count += 1L
    }
    let abs_z = abs_int64_saturating(z)
    if abs_z > max_abs_seek {
      max_abs_seek = abs_z
    }
    if samples.length() < MAX_SAMPLE_CONTROLS {
      samples.push({
        index: control_index,
        add_bytes: x,
        extra_bytes: y,
        seek_offset: z,
      })
    }
  }
  for stream in [control, delta, extra] {
    if stream.read(1).length() != 0 {
      raise InspectionFailed(
        apply_error(
          InvalidField,
          stream.stage,
          "unconsumed_decoded_data",
          None,
          None,
        ),
      )
    }
  }
  let header = ranges.info()
  let deep : DeepPatchInfo = {
    header,
    control_count,
    diff_bytes,
    extra_bytes,
    expanded_bytes: budget.emitted,
  }
  let ctrl_compressed_bytes = header.control_length
  let diff_compressed_bytes = header.diff_length
  let extra_compressed_bytes = header.extra_length
  let total_compressed_bytes = ctrl_compressed_bytes +
    diff_compressed_bytes +
    extra_compressed_bytes
  let expansion_ratio_permille = ratio_permille(
    deep.expanded_bytes,
    total_compressed_bytes,
  )
  let diff_share_permille = ratio_permille(deep.diff_bytes, header.new_bytes)
  let extra_share_permille = ratio_permille(deep.extra_bytes, header.new_bytes)
  let patch_to_output_permille = ratio_permille(
    header.patch_bytes,
    header.new_bytes,
  )
  let required_limits : Limits = {
    ..Limits::for_apply(),
    max_new_bytes: min_positive_limit(header.new_bytes),
    max_patch_bytes: min_positive_limit(header.patch_bytes),
    max_output_bytes: min_positive_limit(header.new_bytes),
    max_decompressed_bytes: min_positive_limit(deep.expanded_bytes),
    max_control_instructions: min_positive_limit(deep.control_count),
  }
  let (risk_level, risk_flags) = evaluate_risk_flags(
    deep, total_compressed_bytes, expansion_ratio_permille, extra_share_permille,
    patch_to_output_permille,
  )
  {
    deep,
    ctrl_compressed_bytes,
    diff_compressed_bytes,
    extra_compressed_bytes,
    total_compressed_bytes,
    expansion_ratio_permille,
    diff_share_permille,
    extra_share_permille,
    patch_to_output_permille,
    negative_seek_count,
    max_abs_seek,
    required_limits,
    risk_level,
    risk_flags,
    sample_controls: ReadOnlyArray::makei(samples.length(), i => samples[i]),
  }
}

///|
/// Perform bounded preflight forensics and security analysis on a single
/// BSDIFF40 patch without needing old bytes or allocating restored output.
/// Fails closed with the exact same structured errors as `inspect_deep` when
/// limits are invalid, exceeded, or the patch is malformed.
pub fn analyze_patch(
  patch : Bytes,
  limits : Limits,
) -> Result[PatchAnalysis, BsdiffError] {
  let ranges = match parse_header(patch, limits) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  if ranges.new_size > limits.max_new_bytes {
    return Err(
      format_error(
        ResourceLimitExceeded,
        Header,
        None,
        Some(24L),
        Some("max_new_bytes"),
        Some(ranges.new_size),
        Some(limits.max_new_bytes),
      ),
    )
  }
  Ok(analyze_streams(patch, ranges, limits)) catch {
    InspectionFailed(error) => Err(error)
  }
}
