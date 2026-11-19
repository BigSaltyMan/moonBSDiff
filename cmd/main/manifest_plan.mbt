///|
priv struct PlanEdge {
  path : String
  old : ManifestIdentity
  new : ManifestIdentity
  patch : ManifestIdentity
}

///|
fn plan_steps(
  outgoing : Map[ManifestIdentity, Array[PlanEdge]],
  start : ManifestIdentity,
  target : ManifestIdentity,
  depth : Int64,
  track_hops : Bool,
) -> (Int64, Array[PlanEdge])? {
  // When the cap can exclude a simple path, a cheaper arrival with more
  // hops cannot replace an arrival that has more steps left.
  let state_key = (vertex, hops) => (vertex, if track_hops { hops } else { 0L })
  let initial = state_key(start, 0L)
  // The core queue is a max-heap. Negate cost, hops and insertion sequence
  // so the cheapest, shortest and earliest queued entry is popped first.
  let queue = @priority_queue.from_array([(0L, 0L, 0L, start)])
  let scores = Map([(initial, (0L, 0L))])
  let predecessor : Map[(ManifestIdentity, Int64), (PlanEdge, Int64)] = Map([])
  let mut sequence = 0L
  while queue.pop() is Some((cost_key, hops_key, _, vertex)) {
    let cost = -cost_key
    let hops = -hops_key
    let state = state_key(vertex, hops)
    if scores.get(state) != Some((cost, hops)) {
      continue
    }
    if vertex == target {
      let steps : Array[PlanEdge] = []
      let mut at = state
      while at != initial {
        let (edge, prior_hops) = predecessor[at]
        steps.push(edge)
        at = state_key(edge.old, prior_hops)
      }
      return Some((cost, steps.rev()))
    }
    if hops == depth {
      continue
    }
    if outgoing.get(vertex) is Some(edges) {
      for edge in edges {
        // Depth is capped by the Int32-indexed candidate count, and each
        // preflighted weight is at most Int32.max. Each settled layer scans
        // each edge at most once. The total cost and sequence fit in Int64.
        let next_cost = cost + edge.patch.size
        let next_hops = hops + 1L
        let score = (next_cost, next_hops)
        let next_state = state_key(edge.new, next_hops)
        if scores.get(next_state) is Some(previous) && previous <= score {
          continue
        }
        scores[next_state] = score
        predecessor[next_state] = (edge, hops)
        sequence += 1L
        queue.push((-next_cost, -next_hops, -sequence, edge.new))
      }
    }
  }
  None
}

///|
fn simple_path_depth(
  outgoing : Map[ManifestIdentity, Array[PlanEdge]],
  candidates : Int64,
) -> Int64 {
  let vertices : Map[ManifestIdentity, Unit] = Map([])
  for old, edges in outgoing {
    vertices[old] = ()
    for edge in edges {
      vertices[edge.new] = ()
    }
  }
  // Deleting a cycle lowers cost or preserves cost with fewer steps.
  // An optimal nonempty route uses distinct identities and candidate edges.
  candidates.min((vertices.length().to_int64() - 1L).max(0L))
}

///|
fn plan_edge_json(edge : PlanEdge) -> @json.Json {
  @json.Json::object({
    "manifest_path": @json.Json::string(edge.path),
    "old": manifest_identity_json(edge.old),
    "new": manifest_identity_json(edge.new),
    "patch": manifest_identity_json(edge.patch),
  })
}

///|
fn manifest_plan_command(config : CliConfig) -> Unit {
  let target_path = config.target_manifest.unwrap()
  let marker = read_prepared_manifest(
    "manifest plan",
    target_path,
    config.limits,
  )
  let target = manifest_identity(marker.new)
  let old_path = config.files[0]
  let start = installed_identity("manifest plan", old_path, config.limits)
  let outgoing : Map[ManifestIdentity, Array[PlanEdge]] = Map([])
  for i in 1..<config.files.length() {
    let path = config.files[i]
    let candidate = if path == target_path {
      marker
    } else {
      read_prepared_manifest("manifest plan", path, config.limits)
    }
    let old = manifest_identity(candidate.old)
    outgoing
    .get_or_init(old, () => [])
    .push({
      path,
      old,
      new: manifest_identity(candidate.new),
      patch: manifest_identity(candidate.patch),
    })
  }
  let candidates = (config.files.length() - 1).to_int64()
  let (depth, track_hops) = match config.max_steps {
    Some(requested) => {
      let simple_bound = simple_path_depth(outgoing, candidates)
      (requested.min(simple_bound), requested < simple_bound)
    }
    None => (candidates, false)
  }
  guard plan_steps(outgoing, start, target, depth, track_hops)
    is Some((cost, steps)) else {
    let restriction = match config.max_steps {
      Some(requested) =>
        " (effective --max-steps=\{depth}, requested \{requested})"
      None => ""
    }
    failure(
      "manifest plan: no reachable path from '\{old_path}' to the target in '\{target_path}'" +
      restriction,
    )
    return
  }
  println(
    @json.Json::object({
      "schema_version": @json.Json::number(1.0),
      "start": manifest_identity_json(start),
      "target": manifest_identity_json(target),
      "total_patch_bytes": @json.Json::string("\{cost}"),
      "steps": @json.Json::array(steps.map(plan_edge_json)),
    }).stringify(),
  )
}
