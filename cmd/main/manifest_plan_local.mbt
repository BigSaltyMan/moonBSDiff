///|
priv struct LocalPlanCandidate {
  manifest_path : String
  patch_path : String
  manifest : @manifest.PreparedManifest
}

///|
fn manifest_plan_local_command(config : CliConfig) -> Unit {
  let operation = config.operation
  let limits = config.limits
  let target_path = config.target_manifest.unwrap()
  let target_data = read_manifest_data(operation, target_path)
  let target = match @manifest.prepare_target(target_data, limits) {
    Ok(identity) => identity
    Err(error) => plan_manifest_failure(operation, target_path, error)
  }
  let start = installed_identity(operation, config.files[0], limits)
  let scanned : Map[String, Unit] = Map([])
  let patches : Map[(Int64, String), String] = Map([])
  for path in config.local_patches {
    if scanned.contains(path) {
      continue
    }
    scanned[path] = ()
    let data = read_input(
      "\{operation} read patch (max_patch_bytes=\{limits.max_patch_bytes})",
      path,
      limits.max_patch_bytes,
    )
    let identity = @manifest.ContentIdentity::of_bytes(data)
    // Keep the first supplied path for each exact content identity.
    patches.get_or_init((identity.size, identity.hash), () => path) |> ignore
  }
  let entries : Array[LocalPlanCandidate] = []
  let manifests : Map[
    String,
    Result[@manifest.PreparedManifest, @manifest.ManifestError],
  ] = Map([])
  for i in 1..<config.files.length() {
    let path = config.files[i]
    let prepared = manifests.get_or_init(path, () => {
      let data = if path == target_path {
        target_data
      } else {
        read_manifest_data(operation, path)
      }
      @manifest.prepare(data, limits)
    })
    match prepared {
      Ok(manifest) =>
        if patches.get((manifest.patch.size, manifest.patch.hash))
          is Some(patch_path) {
          entries.push({ manifest_path: path, patch_path, manifest, })
        }
      Err(error) if plan_edge_over_budget(error) => ()
      Err(error) => plan_manifest_failure(operation, path, error)
    }
  }
  let candidates = entries.map(entry => entry.manifest)
  let route = match
    @manifest.plan(start, target, candidates, max_steps?=config.max_steps) {
    Ok(route) => route
    Err(error) => {
      plan_failure(error, config)
      return
    }
  }
  let steps : Array[@json.Json] = []
  for index in route.candidate_indices {
    let entry = entries[index]
    steps.push(
      plan_edge_json(
        entry.manifest_path,
        entry.manifest,
        patch_path=entry.patch_path,
      ),
    )
  }
  println(
    @json.Json::object({
      "schema_version": @json.Json::number(1.0),
      "start": manifest_identity_json(start),
      "target": manifest_identity_json(target),
      "total_patch_bytes": @json.Json::string("\{route.total_patch_bytes}"),
      "download_bytes": @json.Json::string("0"),
      "steps": @json.Json::array(steps),
    }).stringify(),
  )
}
