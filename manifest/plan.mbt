///|
/// The order and declared download bytes of a route through prepared manifests.
pub struct RoutePlan {
  total_patch_bytes : Int64
  candidate_indices : ReadOnlyArray[Int32]
}

///|
#derive(Eq, Debug)
pub(all) enum PlanError {
  InvalidMaxSteps(Int64)
  NoRoute(effective_max_steps~ : Int64?)
}

///|
pub extend PlanError with Eq::{equal, not_equal}

///|
pub extend PlanError with @debug.Debug::{to_repr}

///|
type PlanVertex = (Int64, String)

///|
fn plan_vertex(identity : ContentIdentity) -> PlanVertex {
  (identity.size, identity.hash)
}

///|
priv struct PlanEdge {
  index : Int32
  old : PlanVertex
  new : PlanVertex
  patch_bytes : Int64
}

///|
fn plan_steps(
  outgoing : Map[PlanVertex, Array[PlanEdge]],
  start : PlanVertex,
  target : PlanVertex,
  depth : Int64,
  track_hops : Bool,
) -> RoutePlan? {
  // When the cap can exclude a simple path, a cheaper arrival with more
  // hops cannot replace an arrival that has more steps left.
  let state_key = (vertex, hops) => (vertex, if track_hops { hops } else { 0L })
  let initial = state_key(start, 0L)
  // The core queue is a max-heap. Negate cost, hops and insertion sequence
  // so the cheapest, shortest and earliest queued entry is popped first.
  let queue = @priority_queue.from_array([(0L, 0L, 0L, start)])
  let scores = Map([(initial, (0L, 0L))])
  let predecessor : Map[(PlanVertex, Int64), (PlanEdge, Int64)] = Map([])
  let mut sequence = 0L
  while queue.pop() is Some((cost_key, hops_key, _, vertex)) {
    let cost = -cost_key
    let hops = -hops_key
    let state = state_key(vertex, hops)
    if scores.get(state) != Some((cost, hops)) {
      continue
    }
    if vertex == target {
      let steps : Array[Int32] = []
      let mut at = state
      while at != initial {
        let (edge, prior_hops) = predecessor[at]
        steps.push(edge.index)
        at = state_key(edge.old, prior_hops)
      }
      return Some({
        total_patch_bytes: cost,
        candidate_indices: ReadOnlyArray::makei(steps.length(), i => {
          steps[steps.length() - 1 - i]
        }),
      })
    }
    if hops == depth {
      continue
    }
    if outgoing.get(vertex) is Some(edges) {
      for edge in edges {
        // Depth is capped by the Int32-indexed candidate count, and each
        // preflighted weight is at most Int32.max. Each settled layer scans
        // each edge at most once. The total cost and sequence fit in Int64.
        let next_cost = cost + edge.patch_bytes
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
  outgoing : Map[PlanVertex, Array[PlanEdge]],
  candidates : Int64,
) -> Int64 {
  let vertices : Map[PlanVertex, Unit] = Map([])
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
/// Choose the least declared download bytes, then the fewest steps.
/// Equal scores keep discovery order, visiting each identity's outgoing
/// candidates in input order. Indices are zero-based and in application order.
pub fn plan(
  start : ContentIdentity,
  target : ContentIdentity,
  candidates : Array[PreparedManifest],
  max_steps? : Int64,
) -> Result[RoutePlan, PlanError] {
  if max_steps is Some(requested) && requested <= 0L {
    return Err(InvalidMaxSteps(requested))
  }
  if start == target {
    return Ok({ total_patch_bytes: 0L, candidate_indices: [], })
  }
  let outgoing : Map[PlanVertex, Array[PlanEdge]] = Map([])
  for index, candidate in candidates {
    let old = plan_vertex(candidate.old)
    outgoing
    .get_or_init(old, () => [])
    .push({
      index,
      old,
      new: plan_vertex(candidate.new),
      patch_bytes: candidate.patch.size,
    })
  }
  let count = candidates.length().to_int64()
  let (depth, track_hops) = match max_steps {
    Some(requested) => {
      let simple_bound = simple_path_depth(outgoing, count)
      (requested.min(simple_bound), requested < simple_bound)
    }
    None => (count, false)
  }
  match
    plan_steps(
      outgoing,
      plan_vertex(start),
      plan_vertex(target),
      depth,
      track_hops,
    ) {
    Some(route) => Ok(route)
    None => Err(NoRoute(effective_max_steps=max_steps.map(_ => depth)))
  }
}

///|
/// Download decision for a release that offers the complete target.
pub(all) enum UpdatePlan {
  UpToDate
  Patches(RoutePlan)
  FullFile(ContentIdentity)
}

///|
/// Compare declared patch bytes with the target's original byte size.
/// A tie favors the full file. The caller supplies its location and verifies
/// the downloaded bytes against the returned identity.
pub fn plan_update(
  start : ContentIdentity,
  target : ContentIdentity,
  candidates : Array[PreparedManifest],
  max_steps? : Int64,
) -> Result[UpdatePlan, PlanError] {
  match plan(start, target, candidates, max_steps?) {
    Ok(_) if start == target => Ok(UpToDate)
    Ok(route) if route.total_patch_bytes < target.size => Ok(Patches(route))
    Ok(_) | Err(NoRoute(..)) => Ok(FullFile(target))
    Err(error) => Err(error)
  }
}
