///|
extern "C" fn delivered_output() -> Int32 = "mbsd_delivery_committed"

///|
fn diff_many_io_error() -> String {
  @utf8.decode_lossy(io_error()[:])
}

///|
fn diff_many_failure(
  group : Int32,
  completed : Int32,
  patch_delivered : Bool,
  reason : String,
) -> Unit {
  let patch_state = if patch_delivered { "yes" } else { "no" }
  failure(
    "diff-many group \{group} failed (completed groups: \{completed}, group patch delivered: \{patch_state}): " +
    reason,
  )
}

///|
// Only path metadata is used here. Include all inputs, even a missing leaf,
// so a prior output cannot become an input for a later group.
fn diff_many_preflight(files : Array[String]) -> Result[Unit, (Int32, String)] {
  let paths = files.map(path_bytes)
  for output in 2..<files.length() {
    let role = (output - 1) % 3
    if role == 0 {
      continue
    }
    let group = (output - 1) / 3 + 1
    let output_path = files[output]
    if io_check(paths[0], paths[output - role], paths[output]) == 0 {
      return Err(
        (group, "preflight output '\{output_path}': " + diff_many_io_error()),
      )
    }
    for other in 0..<files.length() {
      let is_input = other == 0 || (other - 1) % 3 == 0
      if !is_input && other >= output {
        continue
      }
      if io_pair_check(paths[output], paths[other]) == 0 {
        let other_role = if is_input { "input" } else { "output" }
        return Err(
          (
            group,
            "preflight output '\{output_path}' against \{other_role} '\{files[other]}': " +
            diff_many_io_error(),
          ),
        )
      }
    }
  }
  if io_input_check(paths[0]) == 0 {
    return Err((1, "preflight input '\{files[0]}': " + diff_many_io_error()))
  }
  for idx = 1; idx < files.length(); idx = idx + 3 {
    let group = (idx - 1) / 3 + 1
    if io_input_check(paths[idx]) == 0 {
      return Err(
        (group, "preflight input '\{files[idx]}': " + diff_many_io_error()),
      )
    }
  }
  Ok(())
}

///|
fn diff_many_read(path : String, cap : Int64) -> Result[Bytes, String] {
  let bytes = io_read(path_bytes(path), cap.to_int())
  if io_failed() != 0 {
    Err("'\{path}': " + diff_many_io_error())
  } else {
    Ok(bytes)
  }
}

///|
fn diff_many_command(config : CliConfig) -> Unit {
  let files = config.files
  let limits = config.limits
  match diff_many_preflight(files) {
    Err((group, reason)) => {
      diff_many_failure(group, 0, false, reason)
      return
    }
    Ok(_) => ()
  }
  let old = match diff_many_read(files[0], limits.max_old_bytes) {
    Ok(bytes) => bytes
    Err(error) => {
      diff_many_failure(1, 0, false, "read shared old input: " + error)
      return
    }
  }
  let index = match @manifest.BundleIndex::build(old, limits) {
    Ok(index) => index
    Err(error) => {
      diff_many_failure(
        1,
        0,
        false,
        "build index for '\{files[0]}': " + @debug.to_string(error),
      )
      return
    }
  }
  for first = 1; first < files.length(); first = first + 3 {
    let completed = (first - 1) / 3
    let group = completed + 1
    let new_path = files[first]
    let patch_path = files[first + 1]
    let manifest_path = files[first + 2]
    let new = match diff_many_read(new_path, limits.max_new_bytes) {
      Ok(bytes) => bytes
      Err(error) => {
        diff_many_failure(group, completed, false, "read new input: " + error)
        return
      }
    }
    let bundle = match index.diff_with_options(new, limits, config.options) {
      Ok(bundle) => bundle
      Err(error) => {
        diff_many_failure(
          group,
          completed,
          false,
          "generate for '\{new_path}': " + @debug.to_string(error),
        )
        return
      }
    }
    if io_deliver(path_bytes(patch_path), bundle.patch) == 0 {
      diff_many_failure(
        group,
        completed,
        delivered_output() != 0,
        "deliver patch '\{patch_path}': " + diff_many_io_error(),
      )
      return
    }
    if io_deliver(path_bytes(manifest_path), bundle.manifest) == 0 {
      let (complete, state) = if delivered_output() != 0 {
        (completed + 1, "delivered with an error")
      } else {
        (completed, "not delivered")
      }
      diff_many_failure(
        group,
        complete,
        true,
        "manifest '\{manifest_path}' \{state}: " + diff_many_io_error(),
      )
      return
    }
  }
}
