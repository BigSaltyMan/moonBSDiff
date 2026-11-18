///|
#borrow(patch)
extern "C" fn stream_open_next_patch(patch : Bytes, cap : Int64) -> Int32 = "mbsd_stream_open_next_patch"

///|
extern "C" fn stream_use_intermediate(size : Int64) -> Int32 = "mbsd_stream_use_intermediate"

///|
fn chain_check_identity(
  actual : @manifest.ContentIdentity,
  expected : @manifest.ContentIdentity,
  context : String,
) -> Unit raise StreamError {
  stream_require(actual.size == expected.size, context + " size_bytes mismatch")
  stream_require(actual.hash == expected.hash, context + " sha256 mismatch")
}

///|
fn chain_check_output(output : Bytes, path : String) -> Unit raise StreamError {
  stream_require(
    io_pair_check(output, path_bytes(path)) != 0,
    "output/input path precheck for '\{path}'",
  )
}

///|
fn chain_preflight(
  config : CliConfig,
  progress : StreamProgress,
) -> Array[@manifest.PreparedManifest] raise {
  let files = config.files
  let target_path = config.target_manifest.unwrap()
  let output = path_bytes(files[1])
  stream_require(
    io_check(path_bytes(files[0]), path_bytes(target_path), output) != 0,
    "output precheck for '\{files[1]}'",
  )
  chain_check_output(output, files[0])
  chain_check_output(output, target_path)
  let target = stream_read_manifest(target_path, config.limits, progress)
  let prepared : Array[@manifest.PreparedManifest] = []
  for i = 2; i < files.length(); i = i + 2 {
    progress.chain_step = prepared.length() + 1
    progress.checkpoint(2)
    let patch_path = files[i]
    let manifest_path = files[i + 1]
    chain_check_output(output, patch_path)
    chain_check_output(output, manifest_path)
    let step = if manifest_path == target_path {
      target
    } else {
      stream_read_manifest(manifest_path, config.limits, progress)
    }
    if prepared.length() != 0 {
      chain_check_identity(
        prepared[prepared.length() - 1].new,
        step.old,
        "previous new vs old in '\{manifest_path}'",
      )
    }
    prepared.push(step)
  }
  chain_check_identity(
    prepared[prepared.length() - 1].new,
    target.new,
    "final new vs target in '\{target_path}'",
  )
  prepared
}

///|
fn stream_chain(config : CliConfig, progress : StreamProgress) -> Unit raise {
  let prepared = chain_preflight(config, progress)
  let files = config.files
  let limits = config.limits
  for i in 0..<prepared.length() {
    progress.chain_step = i + 1
    progress.restored = 0L
    progress.reported = 0L
    progress.total = None
    progress.phase("preparing")
    // The intermediate was fully checked and transferred by handle before
    // this checkpoint. A cancelled next step never opens its patch.
    progress.checkpoint(if i == 0 { 2 } else { 24 })
    let step = prepared[i]
    let patch_path = files[2 + i * 2]
    if i == 0 {
      stream_require(
        stream_open(
          path_bytes(files[0]),
          path_bytes(patch_path),
          limits.max_old_bytes,
          limits.max_patch_bytes,
        ) !=
        0,
        "open old input and patch '\{patch_path}'",
      )
      verify_stream_copy(0, "old input", step.old, progress)
    } else {
      // Preflight checked that the previous output identity is this step's
      // bounded old identity. The private input was never reopened by path.
      stream_require(
        stream_open_next_patch(path_bytes(patch_path), limits.max_patch_bytes) !=
        0,
        "open patch '\{patch_path}'",
      )
    }
    verify_stream_copy(1, "patch input", step.patch, progress)
    progress.checkpoint(23)
    let expected = Some(step.new)
    let info = stream_prepare_patch(limits, expected, progress)
    if i + 1 == prepared.length() {
      stream_restore_output(files[1], info, limits, progress, expected)
    } else {
      stream_require(stream_copy_begin() != 0, "create private intermediate")
      stream_execute(info, limits, progress, expected, data => {
        stream_require(
          stream_copy_write(data) != 0,
          "write private intermediate",
        )
      })
      progress.checkpoint(40)
      stream_require(
        stream_use_intermediate(step.new.size) != 0,
        "retain verified private intermediate",
      )
      progress.emit(
        "step_verified", "Intermediate verified and ready for the next step",
      )
    }
  }
}
