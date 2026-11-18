///|
#borrow(patch)
extern "C" fn stream_open_next_patch(patch : Bytes, cap : Int64) -> Int32 = "mbsd_stream_open_next_patch"

///|
extern "C" fn stream_use_intermediate(size : Int64) -> Int32 = "mbsd_stream_use_intermediate"

///|
priv struct ChainPaths {
  old : String
  output : String?
  pairs : Array[(String, String)]
}

///|
fn is_chain(operation : String) -> Bool {
  operation == "patch-chain" || operation == "verify-chain"
}

///|
fn chain_first_pair(operation : String) -> Int32 {
  if operation == "patch-chain" {
    2
  } else {
    1
  }
}

///|
fn chain_paths(config : CliConfig) -> ChainPaths {
  let files = config.files
  let first_pair = chain_first_pair(config.operation)
  let pairs = Array::makei((files.length() - first_pair) / 2, i => {
    let offset = first_pair + i * 2
    (files[offset], files[offset + 1])
  })
  {
    old: files[0],
    output: if first_pair == 2 {
      Some(files[1])
    } else {
      None
    },
    pairs,
  }
}

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
  paths : ChainPaths,
  progress : StreamProgress,
) -> Array[@manifest.PreparedManifest] raise {
  let target_path = config.target_manifest.unwrap()
  let output = if paths.output is Some(target) {
    let out = path_bytes(target)
    stream_require(
      io_check(path_bytes(paths.old), path_bytes(target_path), out) != 0,
      "output precheck for '\{target}'",
    )
    chain_check_output(out, paths.old)
    chain_check_output(out, target_path)
    Some(out)
  } else {
    None
  }
  let target = stream_read_manifest(target_path, config.limits, progress)
  let prepared : Array[@manifest.PreparedManifest] = []
  for (patch_path, manifest_path) in paths.pairs {
    progress.chain_step = prepared.length() + 1
    progress.checkpoint(2)
    if output is Some(out) {
      chain_check_output(out, patch_path)
      chain_check_output(out, manifest_path)
    }
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
fn stream_chain(
  config : CliConfig,
  paths : ChainPaths,
  progress : StreamProgress,
) -> Unit raise {
  let prepared = chain_preflight(config, paths, progress)
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
    let (patch_path, _) = paths.pairs[i]
    if i == 0 {
      stream_require(
        stream_open(
          path_bytes(paths.old),
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
      if paths.output is Some(target) {
        stream_restore_output(target, info, limits, progress, expected)
      } else {
        stream_execute(info, limits, progress, expected, _ => ())
      }
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
