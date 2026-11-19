///|
fn plan_edge_json(
  path : String,
  candidate : @manifest.PreparedManifest,
) -> @json.Json {
  @json.Json::object({
    "manifest_path": @json.Json::string(path),
    "old": manifest_identity_json(candidate.old),
    "new": manifest_identity_json(candidate.new),
    "patch": manifest_identity_json(candidate.patch),
  })
}

///|
fn plan_steps_json(
  files : Array[String],
  candidates : Array[@manifest.PreparedManifest],
  route : @manifest.RoutePlan,
) -> @json.Json {
  let steps : Array[@json.Json] = []
  for index in route.candidate_indices {
    steps.push(plan_edge_json(files[index + 1], candidates[index]))
  }
  @json.Json::array(steps)
}

///|
fn update_plan_json(
  start : @manifest.ContentIdentity,
  target : @manifest.ContentIdentity,
  files : Array[String],
  candidates : Array[@manifest.PreparedManifest],
  decision : @manifest.UpdatePlan,
) -> @json.Json {
  let fields = {
    "schema_version": @json.Json::number(1.0),
    "start": manifest_identity_json(start),
    "target": manifest_identity_json(target),
  }
  let (strategy, download_bytes) = match decision {
    UpToDate => ("already-current", 0L)
    Patches(route) => {
      fields["steps"] = plan_steps_json(files, candidates, route)
      ("patches", route.total_patch_bytes)
    }
    FullFile(identity) => ("full-file", identity.size)
  }
  fields["strategy"] = @json.Json::string(strategy)
  fields["download_bytes"] = @json.Json::string("\{download_bytes}")
  @json.Json::object(fields)
}

///|
fn plan_failure(error : @manifest.PlanError, config : CliConfig) -> Unit {
  match error {
    NoRoute(effective_max_steps~) => {
      let old_path = config.files[0]
      let target_path = config.target_manifest.unwrap()
      let restriction = if effective_max_steps is Some(depth) &&
        config.max_steps is Some(requested) {
        " (effective --max-steps=\{depth}, requested \{requested})"
      } else {
        ""
      }
      failure(
        "manifest plan: no reachable path from '\{old_path}' to the target in '\{target_path}'" +
        restriction,
      )
    }
    InvalidMaxSteps(_) =>
      // CLI argument parsing already rejects this case.
      @env.exit(2)
  }
}

///|
fn manifest_plan_command(config : CliConfig) -> Unit {
  let target_path = config.target_manifest.unwrap()
  let marker = read_prepared_manifest(
    "manifest plan",
    target_path,
    config.limits,
  )
  let old_path = config.files[0]
  let start = installed_identity("manifest plan", old_path, config.limits)
  let candidates : Array[@manifest.PreparedManifest] = []
  for i in 1..<config.files.length() {
    let path = config.files[i]
    candidates.push(
      if path == target_path {
        marker
      } else {
        read_prepared_manifest("manifest plan", path, config.limits)
      },
    )
  }
  if config.allow_full {
    match
      @manifest.plan_update(
        start,
        marker.new,
        candidates,
        max_steps?=config.max_steps,
      ) {
      Ok(decision) =>
        println(
          update_plan_json(
            start,
            marker.new,
            config.files,
            candidates,
            decision,
          ).stringify(),
        )
      Err(error) => plan_failure(error, config)
    }
    return
  }
  let route = match
    @manifest.plan(start, marker.new, candidates, max_steps?=config.max_steps) {
    Ok(route) => route
    Err(error) => {
      plan_failure(error, config)
      return
    }
  }
  println(
    @json.Json::object({
      "schema_version": @json.Json::number(1.0),
      "start": manifest_identity_json(start),
      "target": manifest_identity_json(marker.new),
      "total_patch_bytes": @json.Json::string("\{route.total_patch_bytes}"),
      "steps": plan_steps_json(config.files, candidates, route),
    }).stringify(),
  )
}
