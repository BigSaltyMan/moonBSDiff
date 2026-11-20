///|
fn plan_edge_json(
  path : String,
  candidate : @manifest.PreparedManifest,
  patch_path? : String,
) -> @json.Json {
  let fields = {
    "manifest_path": @json.Json::string(path),
    "old": manifest_identity_json(candidate.old),
    "new": manifest_identity_json(candidate.new),
    "patch": manifest_identity_json(candidate.patch),
  }
  if patch_path is Some(local_path) {
    fields["patch_path"] = @json.Json::string(local_path)
  }
  @json.Json::object(fields)
}

///|
type PlanCandidate = (String, @manifest.PreparedManifest)

///|
fn plan_steps_json(
  entries : Array[PlanCandidate],
  route : @manifest.RoutePlan,
) -> @json.Json {
  let steps : Array[@json.Json] = []
  for index in route.candidate_indices {
    let (path, candidate) = entries[index]
    steps.push(plan_edge_json(path, candidate))
  }
  @json.Json::array(steps)
}

///|
fn check_download_budget(cost : Int64, budget : Int64?) -> Unit {
  if budget is Some(cap) && cost > cap {
    failure(
      "manifest plan: minimum download \{cost} bytes exceeds budget \{cap} bytes",
    )
  }
}

///|
fn print_update_plan(
  start : @manifest.ContentIdentity,
  target : @manifest.ContentIdentity,
  entries : Array[PlanCandidate],
  decision : @manifest.UpdatePlan,
  budget : Int64?,
) -> Unit {
  let (strategy, download_bytes) = match decision {
    UpToDate => ("already-current", 0L)
    Patches(route) => ("patches", route.total_patch_bytes)
    FullFile(identity) => ("full-file", identity.size)
  }
  check_download_budget(download_bytes, budget)
  let fields = {
    "schema_version": @json.Json::number(1.0),
    "start": manifest_identity_json(start),
    "target": manifest_identity_json(target),
  }
  if decision is Patches(route) {
    fields["steps"] = plan_steps_json(entries, route)
  }
  fields["strategy"] = @json.Json::string(strategy)
  fields["download_bytes"] = @json.Json::string("\{download_bytes}")
  println(@json.Json::object(fields).stringify())
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
      let reason = if config.operation == "manifest plan-local" {
        "local patches cannot connect"
      } else {
        "no reachable path from"
      }
      failure(
        "\{config.operation}: \{reason} '\{old_path}' to the target in '\{target_path}'" +
        restriction,
      )
    }
    InvalidMaxSteps(_) =>
      // CLI argument parsing already rejects this case.
      @env.exit(2)
  }
}

///|
fn[T] plan_manifest_failure(
  operation : String,
  path : String,
  error : @manifest.ManifestError,
) -> T {
  manifest_failure("\{operation} '\{path}': " + manifest_diagnostic(error))
}

///|
fn plan_edge_over_budget(error : @manifest.ManifestError) -> Bool {
  match error {
    LimitExceeded(field~, ..) =>
      field == "max_old_bytes" ||
      field == "max_patch_bytes" ||
      field == "max_new_bytes" ||
      field == "max_output_bytes"
    _ => false
  }
}

///|
fn manifest_plan_command(config : CliConfig) -> Unit {
  let limits = config.limits
  let target_path = config.target_manifest.unwrap()
  let operation = config.operation
  let data = read_manifest_data(operation, target_path)
  let marker = @manifest.prepare(data, limits)
  // Successful patch preflight already includes the target checks. If only
  // old or patch limits prevent that preflight, use the same bytes to check
  // the target identity. Keep the patch result for any matching candidate.
  let target = match marker {
    Ok(prepared) => prepared.new
    Err(LimitExceeded(field~, ..)) if field == "max_old_bytes" ||
      field == "max_patch_bytes" =>
      match @manifest.prepare_target(data, limits) {
        Ok(identity) => identity
        Err(error) => plan_manifest_failure(operation, target_path, error)
      }
    Err(error) => plan_manifest_failure(operation, target_path, error)
  }
  let old_path = config.files[0]
  let start = installed_identity("manifest plan", old_path, limits)
  let entries : Array[PlanCandidate] = []
  for i in 1..<config.files.length() {
    let path = config.files[i]
    let prepared = if path == target_path {
      marker
    } else {
      @manifest.prepare(read_manifest_data("manifest plan", path), limits)
    }
    match prepared {
      Ok(candidate) => entries.push((path, candidate))
      Err(error) if config.allow_full && plan_edge_over_budget(error) => ()
      Err(error) => plan_manifest_failure(operation, path, error)
    }
  }
  let candidates = entries.map(entry => entry.1)
  if config.allow_full {
    match
      @manifest.plan_update(
        start,
        target,
        candidates,
        max_steps?=config.max_steps,
      ) {
      Ok(decision) =>
        print_update_plan(
          start,
          target,
          entries,
          decision,
          config.max_download_bytes,
        )
      Err(error) => plan_failure(error, config)
    }
    return
  }
  let route = match
    @manifest.plan(start, target, candidates, max_steps?=config.max_steps) {
    Ok(route) => route
    Err(error) => {
      plan_failure(error, config)
      return
    }
  }
  check_download_budget(route.total_patch_bytes, config.max_download_bytes)
  println(
    @json.Json::object({
      "schema_version": @json.Json::number(1.0),
      "start": manifest_identity_json(start),
      "target": manifest_identity_json(target),
      "total_patch_bytes": @json.Json::string("\{route.total_patch_bytes}"),
      "steps": plan_steps_json(entries, route),
    }).stringify(),
  )
}
