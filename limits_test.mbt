///|
fn valid() -> @moonbsdiff.Limits {
  {
    max_old_bytes: 1L,
    max_new_bytes: 1L,
    max_patch_bytes: 1L,
    max_output_bytes: 1L,
    max_decompressed_bytes: 1L,
    max_control_instructions: 1L,
    max_sort_work: 1L,
    max_match_work: 1L,
  }
}

///|
test "valid limits and boundaries" {
  let l = valid()
  assert_eq(l.validate(), Ok(()))
  let max : @moonbsdiff.Limits = {
    max_old_bytes: 2147483647L,
    max_new_bytes: 2147483647L,
    max_patch_bytes: 2147483647L,
    max_output_bytes: 2147483647L,
    max_decompressed_bytes: 2147483647L,
    max_control_instructions: 9223372036854775807L,
    max_sort_work: 9223372036854775807L,
    max_match_work: 9223372036854775807L,
  }
  assert_eq(max.validate(), Ok(()))
}

///|
test "invalid values identify field and allow recovery" {
  let bad = { ..valid(), max_old_bytes: 0L, }
  assert_eq(
    bad.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_old_bytes"),
      value: Some(0L),
      limit: Some(2147483647L),
    }),
  )
  let negative = { ..valid(), max_sort_work: -1L, }
  assert_eq(
    negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_sort_work"),
      value: Some(-1L),
      limit: Some(9223372036854775807L),
    }),
  )
  let large = { ..valid(), max_patch_bytes: 2147483648L, }
  assert_eq(
    large.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_patch_bytes"),
      value: Some(2147483648L),
      limit: Some(2147483647L),
    }),
  )
  assert_eq(valid().validate(), Ok(()))
}

///|
test "error details retain context" {
  let err : @moonbsdiff.BsdiffError = {
    kind: TruncatedData,
    stage: Control,
    block: Some("control"),
    offset: Some(12L),
    field: None,
    value: None,
    limit: None,
  }
  assert_eq(err.kind, TruncatedData)
  assert_eq(err.stage, Control)
  assert_eq(err.block, Some("control"))
  assert_eq(err.offset, Some(12L))
}

///|
test "every limit rejects zero and negative values" {
  let max_old_bytes_zero = { ..valid(), max_old_bytes: 0L, }
  assert_eq(
    max_old_bytes_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_old_bytes"),
      value: Some(0L),
      limit: Some(2147483647L),
    }),
  )
  let max_old_bytes_negative = { ..valid(), max_old_bytes: -1L, }
  assert_eq(
    max_old_bytes_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_old_bytes"),
      value: Some(-1L),
      limit: Some(2147483647L),
    }),
  )
  let max_new_bytes_zero = { ..valid(), max_new_bytes: 0L, }
  assert_eq(
    max_new_bytes_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_new_bytes"),
      value: Some(0L),
      limit: Some(2147483647L),
    }),
  )
  let max_new_bytes_negative = { ..valid(), max_new_bytes: -1L, }
  assert_eq(
    max_new_bytes_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_new_bytes"),
      value: Some(-1L),
      limit: Some(2147483647L),
    }),
  )
  let max_patch_bytes_zero = { ..valid(), max_patch_bytes: 0L, }
  assert_eq(
    max_patch_bytes_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_patch_bytes"),
      value: Some(0L),
      limit: Some(2147483647L),
    }),
  )
  let max_patch_bytes_negative = { ..valid(), max_patch_bytes: -1L, }
  assert_eq(
    max_patch_bytes_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_patch_bytes"),
      value: Some(-1L),
      limit: Some(2147483647L),
    }),
  )
  let max_output_bytes_zero = { ..valid(), max_output_bytes: 0L, }
  assert_eq(
    max_output_bytes_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_output_bytes"),
      value: Some(0L),
      limit: Some(2147483647L),
    }),
  )
  let max_output_bytes_negative = { ..valid(), max_output_bytes: -1L, }
  assert_eq(
    max_output_bytes_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_output_bytes"),
      value: Some(-1L),
      limit: Some(2147483647L),
    }),
  )
  let max_decompressed_bytes_zero = { ..valid(), max_decompressed_bytes: 0L, }
  assert_eq(
    max_decompressed_bytes_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_decompressed_bytes"),
      value: Some(0L),
      limit: Some(9223372036854775807L),
    }),
  )
  let max_decompressed_bytes_negative = {
    ..valid(),
    max_decompressed_bytes: -1L,
  }
  assert_eq(
    max_decompressed_bytes_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_decompressed_bytes"),
      value: Some(-1L),
      limit: Some(9223372036854775807L),
    }),
  )
  let max_control_instructions_zero = {
    ..valid(),
    max_control_instructions: 0L,
  }
  assert_eq(
    max_control_instructions_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_control_instructions"),
      value: Some(0L),
      limit: Some(9223372036854775807L),
    }),
  )
  let max_control_instructions_negative = {
    ..valid(),
    max_control_instructions: -1L,
  }
  assert_eq(
    max_control_instructions_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_control_instructions"),
      value: Some(-1L),
      limit: Some(9223372036854775807L),
    }),
  )
  let max_sort_work_zero = { ..valid(), max_sort_work: 0L, }
  assert_eq(
    max_sort_work_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_sort_work"),
      value: Some(0L),
      limit: Some(9223372036854775807L),
    }),
  )
  let max_sort_work_negative = { ..valid(), max_sort_work: -1L, }
  assert_eq(
    max_sort_work_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_sort_work"),
      value: Some(-1L),
      limit: Some(9223372036854775807L),
    }),
  )
  let max_match_work_zero = { ..valid(), max_match_work: 0L, }
  assert_eq(
    max_match_work_zero.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_match_work"),
      value: Some(0L),
      limit: Some(9223372036854775807L),
    }),
  )
  let max_match_work_negative = { ..valid(), max_match_work: -1L, }
  assert_eq(
    max_match_work_negative.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_match_work"),
      value: Some(-1L),
      limit: Some(9223372036854775807L),
    }),
  )
}

///|
test "each buffer ceiling rejects one beyond Int range" {
  let bad_max_old_bytes = { ..valid(), max_old_bytes: 2147483648L, }
  assert_eq(
    bad_max_old_bytes.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_old_bytes"),
      value: Some(2147483648L),
      limit: Some(2147483647L),
    }),
  )
  let bad_max_new_bytes = { ..valid(), max_new_bytes: 2147483648L, }
  assert_eq(
    bad_max_new_bytes.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_new_bytes"),
      value: Some(2147483648L),
      limit: Some(2147483647L),
    }),
  )
  let bad_max_patch_bytes = { ..valid(), max_patch_bytes: 2147483648L, }
  assert_eq(
    bad_max_patch_bytes.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_patch_bytes"),
      value: Some(2147483648L),
      limit: Some(2147483647L),
    }),
  )
  let bad_max_output_bytes = { ..valid(), max_output_bytes: 2147483648L, }
  assert_eq(
    bad_max_output_bytes.validate(),
    Err({
      kind: InvalidConfiguration,
      stage: Configuration,
      block: None,
      offset: None,
      field: Some("max_output_bytes"),
      value: Some(2147483648L),
      limit: Some(2147483647L),
    }),
  )
}
