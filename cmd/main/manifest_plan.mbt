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
) -> (Int64, Array[PlanEdge])? {
  // The core queue is a max-heap. Negate cost, hops and insertion sequence
  // so the cheapest, shortest and earliest queued entry is popped first.
  let queue = @priority_queue.from_array([(0L, 0L, 0L, start)])
  let scores = Map([(start, (0L, 0L))])
  let predecessor : Map[ManifestIdentity, PlanEdge] = Map([])
  let mut sequence = 0L
  while queue.pop() is Some((cost_key, hops_key, _, vertex)) {
    let cost = -cost_key
    let hops = -hops_key
    if scores.get(vertex) != Some((cost, hops)) {
      continue
    }
    if vertex == target {
      let steps : Array[PlanEdge] = []
      let mut at = target
      while at != start {
        let edge = predecessor[at]
        steps.push(edge)
        at = edge.old
      }
      return Some((cost, steps.rev()))
    }
    if outgoing.get(vertex) is Some(edges) {
      for edge in edges {
        // Each edge costs at most Int32.max after preflight. A settled
        // path plus one edge uses at most the Int32-indexed argument count.
        // Even that worst-case cost fits in Int64 (< 2^62).
        let next_cost = cost + edge.patch.size
        let next_hops = hops + 1L
        let score = (next_cost, next_hops)
        if scores.get(edge.new) is Some(previous) && previous <= score {
          continue
        }
        scores[edge.new] = score
        predecessor[edge.new] = edge
        sequence += 1L
        queue.push((-next_cost, -next_hops, -sequence, edge.new))
      }
    }
  }
  None
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
  guard plan_steps(outgoing, start, target) is Some((cost, steps)) else {
    failure(
      "manifest plan: no reachable path from '\{old_path}' to the target in '\{target_path}'",
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
