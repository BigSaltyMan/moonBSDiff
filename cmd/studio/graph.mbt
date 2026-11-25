///|
priv struct GraphEdgeFixture {
  from_version : Int64
  to_version : Int64
  uri : String
  bundle : @manifest.PatchBundle
  patch_identity : @manifest.ContentIdentity
  manifest_sha256 : String
}

///|
priv struct GraphFixtures {
  versions : Array[(Int64, String, Bytes, @manifest.ContentIdentity)]
  edges : Array[GraphEdgeFixture]
}

///|
let graph_fixtures_cache : Ref[GraphFixtures?] = Ref(None)

///|
fn build_graph_fixtures() -> GraphFixtures {
  match graph_fixtures_cache.val {
    Some(cached) => return cached
    None => ()
  }
  let diff_limits = @moonbsdiff.Limits::for_diff()
  // Build 4 realistic ~10 KiB structured firmware images (v1.0 -> v1.1 -> v1.2 -> v2.0).
  let base = structured_firmware_image(10240, 0x51a70001U)
  let v1_bytes = Bytes::from_array(base)

  // v1.1: localized security fix in section 1 (~32 B) + metadata tag
  let v2_arr = mutate_slice(base, 16, b"REL=1.1.0;SEC=CVE-2026-01;ABI=07")
  let v2_arr2 = mutate_slice(v2_arr, 2048, prng_bytes(48, 0x11002201U))
  let v2_bytes = Bytes::from_array(v2_arr2)

  // v1.2: localized protocol upgrade in section 2 (~44 B) + metadata tag
  let v3_arr = mutate_slice(v2_arr2, 16, b"REL=1.2.0;SEC=CVE-2026-02;ABI=07")
  let v3_arr2 = mutate_slice(v3_arr, 5120, prng_bytes(64, 0x22003302U))
  let v3_bytes = Bytes::from_array(v3_arr2)

  // v2.0: major runtime table refresh in section 3 (~96 B) + metadata tag
  let v4_arr = mutate_slice(v3_arr2, 16, b"REL=2.0.0;SEC=CVE-2026-03;ABI=08")
  let v4_arr2 = mutate_slice(v4_arr, 8192, prng_bytes(96, 0x33004403U))
  let v4_bytes = Bytes::from_array(v4_arr2)

  let versions : Array[(Int64, String, Bytes, @manifest.ContentIdentity)] = [
    (1L, "v1.0.0", v1_bytes, @manifest.ContentIdentity::of_bytes(v1_bytes)),
    (2L, "v1.1.0", v2_bytes, @manifest.ContentIdentity::of_bytes(v2_bytes)),
    (3L, "v1.2.0", v3_bytes, @manifest.ContentIdentity::of_bytes(v3_bytes)),
    (4L, "v2.0.0", v4_bytes, @manifest.ContentIdentity::of_bytes(v4_bytes)),
  ]

  let pairs : Array[(Int32, Int32, String)] = [
    (0, 1, "patches/v1.0.0-to-v1.1.0.patch"),
    (1, 2, "patches/v1.1.0-to-v1.2.0.patch"),
    (2, 3, "patches/v1.2.0-to-v2.0.0.patch"),
    (0, 2, "patches/v1.0.0-to-v1.2.0.patch"),
    (1, 3, "patches/v1.1.0-to-v2.0.0.patch"),
  ]
  let edges : Array[GraphEdgeFixture] = []
  for pair in pairs {
    let (fi, ti, uri) = pair
    let (fv, _, old_b, _) = versions[fi]
    let (tv, _, new_b, _) = versions[ti]
    let bundle = @manifest.diff(old_b, new_b, diff_limits).unwrap()
    edges.push({
      from_version: fv,
      to_version: tv,
      uri,
      bundle,
      patch_identity: @manifest.ContentIdentity::of_bytes(bundle.patch),
      manifest_sha256: @manifest_support.sha256_hex(bundle.manifest),
    })
  }
  let built : GraphFixtures = { versions, edges, }
  graph_fixtures_cache.val = Some(built)
  built
}

///|
fn forge_catalog_signature_for_bytes(
  trusted_key_id : String,
  rogue_sig : @manifest.CatalogSignature,
  forged_catalog_bytes : Bytes,
) -> @manifest.CatalogSignature {
  // Reuse a canonical Ed25519 (R, S) signed by an untrusted key while claiming
  // the trusted key_id and matching catalog_sha256 so TrustStore reaches real
  // Ed25519 verification and fails closed with Signature(VerificationFailed).
  let doc = j_obj({
    "schema_version": j_int(1),
    "format": j_str("moonbsdiff-catalog-signature"),
    "algorithm": j_str("ed25519"),
    "key_id": j_str(trusted_key_id),
    "catalog_sha256": j_str(@manifest_support.sha256_hex(forged_catalog_bytes)),
    "signature": j_str(rogue_sig.signature_hex()),
  })
  let json_bytes = @utf8.encode(doc.stringify()[:])
  @manifest.CatalogSignature::from_json_bytes(json_bytes).unwrap()
}

///|
fn find_version_bytes(
  fixtures : GraphFixtures,
  version : Int64,
) -> (Bytes, @manifest.ContentIdentity)? {
  for entry in fixtures.versions {
    let (v, _, b, id) = entry
    if v == version {
      return Some((b, id))
    }
  }
  None
}

///|
fn graph_invalid_request_json(msg : String) -> String {
  j_obj({
    "ok": j_bool(false),
    "attack_mode": j_str("none"),
    "channel": j_str("stable"),
    "catalog_version": j_null(),
    "min_catalog_version": j_null(),
    "min_version": j_null(),
    "current_version": j_null(),
    "target_version": j_null(),
    "signer_key_id": j_null(),
    "trusted_key_ids": j_arr([]),
    "catalog_sha256": j_null(),
    "releases": j_arr([]),
    "patches": j_arr([]),
    "decision": j_str("Rejected"),
    "total_download_bytes": j_i64(0L),
    "full_target_bytes": j_i64(0L),
    "savings_bytes": j_i64(0L),
    "savings_permille": j_i64(0L),
    "verified_steps": j_arr([]),
    "error": j_obj({
      "kind": j_str("InvalidRequest"),
      "field": j_str("request_json"),
      "raw": j_str(msg),
    }),
    "security_verdict": j_obj({
      "status": j_str("BLOCKED"),
      "code": j_str("InvalidRequest"),
      "error_type": j_str("InvalidRequest"),
      "summary": j_str(msg),
      "raw_error": j_str(msg),
    }),
    "catalog_json_preview": j_str(""),
  }).stringify()
}

///|
fn run_graph_scenario_impl(request_json : String) -> String {
  if !js_is_string(request_json) {
    return graph_invalid_request_json("request_json must be a string")
  }
  let fields = match parse_json_object_or_empty(request_json) {
    Ok(f) => f
    Err(msg) => return graph_invalid_request_json(msg)
  }
  let fixtures = build_graph_fixtures()
  let attack_mode = get_opt_string(fields, "attack_mode", "none")
  let req_current = match get_strict_i64_or(fields, "current_version", 1L) {
    Ok(v) => v
    Err(msg) => return graph_invalid_request_json(msg)
  }
  let req_target = match get_strict_i64_or(fields, "target_version", 4L) {
    Ok(v) => v
    Err(msg) => return graph_invalid_request_json(msg)
  }
  let max_steps_opt = match get_strict_opt_i64(fields, "max_steps") {
    Ok(v) => v
    Err(msg) => return graph_invalid_request_json(msg)
  }
  let max_download_opt = match
    get_strict_opt_i64(fields, "max_download_bytes") {
    Ok(v) => v
    Err(msg) => return graph_invalid_request_json(msg)
  }
  let allow_full = get_opt_bool(fields, "allow_full", true)
  let req_min_catalog = match
    get_strict_i64_or(fields, "min_catalog_version", 5L) {
    Ok(v) => v
    Err(msg) => return graph_invalid_request_json(msg)
  }

  // Configure effective scenario parameters per attack mode while keeping user overrides active.
  let current_version = if attack_mode == "downgrade_v1" && req_current < 2L {
    3L
  } else if attack_mode == "tamper_hop" && req_current >= req_target {
    1L
  } else {
    req_current
  }
  let target_version = if attack_mode == "downgrade_v1" {
    1L
  } else if attack_mode == "tamper_hop" && req_current >= req_target {
    4L
  } else {
    req_target
  }
  let effective_allow_full = if attack_mode == "tamper_hop" {
    false
  } else {
    allow_full
  }
  let effective_max_steps = if attack_mode == "tamper_hop" {
    let min_hops = if target_version - current_version >= 3L { 2L } else { 1L }
    match max_steps_opt {
      Some(ms) =>
        if ms > 0L && ms < min_hops {
          Some(min_hops)
        } else {
          Some(ms)
        }
      None => None
    }
  } else {
    max_steps_opt
  }
  let catalog_version = match attack_mode {
    "key_rotation" => 6L
    "replay_old_catalog" => 3L
    _ => 5L
  }
  let effective_min_catalog = if attack_mode == "replay_old_catalog" &&
    req_min_catalog <= 3L {
    5L
  } else {
    req_min_catalog
  }
  let min_version = if attack_mode == "downgrade_v1" { 2L } else { 1L }

  let (sk_a, pk_a) = studio_keypair(1)
  let (sk_b, pk_b) = studio_keypair(2)
  let trust_store = if attack_mode == "key_rotation" {
    @manifest.TrustStore::from_keys([pk_a, pk_b]).unwrap()
  } else {
    @manifest.TrustStore::from_keys([pk_a]).unwrap()
  }
  let trusted_key_ids : Array[@json.Json] = []
  for kid in trust_store.key_ids() {
    trusted_key_ids.push(j_str(kid))
  }

  let cat_releases : Array[@manifest.CatalogRelease] = []
  for entry in fixtures.versions {
    let (v, label, _, content) = entry
    cat_releases.push({ version: v, label, content, })
  }
  let cat_patches : Array[@manifest.CatalogPatch] = []
  let poisoned_edge_index : Int32? = if attack_mode == "poison_fake_patch" {
    Some(fixtures.edges.length())
  } else {
    None
  }
  for e in fixtures.edges {
    cat_patches.push({
      from_version: e.from_version,
      to_version: e.to_version,
      patch: e.patch_identity,
      manifest_sha256: Some(e.manifest_sha256),
      uri: Some(e.uri),
    })
  }
  if attack_mode == "poison_fake_patch" {
    // Attacker injects a fake ultra-cheap 32-byte v1.0 -> v2.0 express patch.
    let fake_bytes = Bytes::make(32, b'\xde')
    cat_patches.push({
      from_version: 1L,
      to_version: 4L,
      patch: @manifest.ContentIdentity::of_bytes(fake_bytes),
      manifest_sha256: None,
      uri: Some("https://evil.cdn.invalid/fake-express.patch"),
    })
  }

  let catalog = @manifest.ReleaseCatalog::new(
    "stable", catalog_version, min_version, cat_releases, cat_patches,
  ).unwrap()
  let catalog_bytes = catalog.to_json_bytes()
  let catalog_sha256 = @manifest_support.sha256_hex(catalog_bytes)
  let catalog_json_preview = bytes_to_utf8_lossy(catalog_bytes)

  let sig = if attack_mode == "key_rotation" {
    sk_b.sign_catalog(catalog_bytes).unwrap()
  } else if attack_mode == "poison_fake_patch" {
    let (sk_rogue, _) = studio_keypair(3)
    let rogue_sig = sk_rogue.sign_catalog(catalog_bytes).unwrap()
    forge_catalog_signature_for_bytes(pk_a.key_id(), rogue_sig, catalog_bytes)
  } else {
    sk_a.sign_catalog(catalog_bytes).unwrap()
  }

  let full_target_bytes = match find_version_bytes(fixtures, target_version) {
    Some((_, id)) => id.size
    None => 0L
  }

  // Helper to assemble the final JSON payload uniformly for every outcome.
  let build_response = fn(
    ok : Bool,
    decision : String,
    active_indices : Array[Int32],
    tampered_edge_index : Int32?,
    total_download_bytes : Int64,
    verified_steps : Array[@json.Json],
    verdict_status : String,
    verdict_code : String,
    verdict_summary : String,
    raw_error : String,
  ) -> String {
    let releases_json : Array[@json.Json] = []
    for entry in fixtures.versions {
      let (v, label, _, content) = entry
      releases_json.push(
        j_obj({
          "version": j_i64(v),
          "label": j_str(label),
          "size_bytes": j_i64(content.size),
          "sha256": j_str(content.hash),
          "is_current": j_bool(v == current_version),
          "is_target": j_bool(v == target_version),
          "revoked": j_bool(v < min_version),
        }),
      )
    }
    let patches_json : Array[@json.Json] = []
    for idx = 0; idx < cat_patches.length(); idx = idx + 1 {
      let p = cat_patches[idx]
      let mut hop_order = -1
      for h = 0; h < active_indices.length(); h = h + 1 {
        if active_indices[h] == idx {
          hop_order = h + 1
        }
      }
      let is_poisoned = poisoned_edge_index == Some(idx)
      let is_tampered = tampered_edge_index == Some(idx)
      patches_json.push(
        j_obj({
          "index": j_int(idx),
          "from_version": j_i64(p.from_version),
          "to_version": j_i64(p.to_version),
          "patch_bytes": j_i64(p.patch.size),
          "patch_sha256": j_str(p.patch.hash),
          "manifest_sha256": j_opt_str(p.manifest_sha256),
          "uri": j_opt_str(p.uri),
          "active": j_bool(hop_order > 0),
          "hop_order": if hop_order > 0 {
            j_int(hop_order)
          } else {
            j_null()
          },
          "poisoned": j_bool(is_poisoned),
          "tampered": j_bool(is_tampered),
        }),
      )
    }
    let savings_bytes = if ok &&
      decision == "Patches" &&
      full_target_bytes > total_download_bytes {
      full_target_bytes - total_download_bytes
    } else if ok && decision == "UpToDate" {
      full_target_bytes
    } else {
      0L
    }
    let savings_permille = if ok && decision == "Patches" {
      permille_saved(full_target_bytes, total_download_bytes)
    } else if ok && decision == "UpToDate" {
      1000L
    } else {
      0L
    }
    j_obj({
      "ok": j_bool(ok),
      "attack_mode": j_str(attack_mode),
      "channel": j_str("stable"),
      "catalog_version": j_i64(catalog_version),
      "min_catalog_version": j_i64(effective_min_catalog),
      "min_version": j_i64(min_version),
      "current_version": j_i64(current_version),
      "target_version": j_i64(target_version),
      "effective_max_steps": j_opt_i64(effective_max_steps),
      "allow_full": j_bool(effective_allow_full),
      "signer_key_id": j_str(sig.key_id()),
      "trusted_key_ids": j_arr(trusted_key_ids),
      "catalog_sha256": j_str(catalog_sha256),
      "releases": j_arr(releases_json),
      "patches": j_arr(patches_json),
      "decision": j_str(decision),
      "total_download_bytes": j_i64(total_download_bytes),
      "full_target_bytes": j_i64(full_target_bytes),
      "savings_bytes": j_i64(savings_bytes),
      "savings_permille": j_i64(savings_permille),
      "verified_steps": j_arr(verified_steps),
      "security_verdict": j_obj({
        "status": j_str(verdict_status),
        "code": j_str(verdict_code),
        "error_type": j_str(verdict_code),
        "summary": j_str(verdict_summary),
        "raw_error": j_str(raw_error),
      }),
      "catalog_json_preview": j_str(catalog_json_preview),
    }).stringify()
  }

  // Step 1: REAL Ed25519 TrustStore verification + anti-replay catalog_version check.
  let verified_catalog = match
    trust_store.verify_catalog(
      catalog_bytes,
      sig,
      min_catalog_version=effective_min_catalog,
    ) {
    Ok(vc) => vc
    Err(err) => {
      let code = catalog_error_code(err)
      let summary = match err {
        @manifest.CatalogError::Signature(_) =>
          "Ed25519 signature verification failed BEFORE catalog parsing or route planning — poisoned edge blocked."
        @manifest.CatalogError::CatalogRollback(..) =>
          "Authentic signed catalog rejected because catalog_version < min_catalog_version (anti-replay floor)."
        _ => "Catalog verification rejected: " + code
      }
      return build_response(
        false,
        "Rejected",
        [],
        None,
        0L,
        [],
        "BLOCKED",
        code,
        summary,
        @debug.to_string(err),
      )
    }
  }

  // Step 2: REAL anti-downgrade, budget, and hop-bounded Dijkstra planning.
  let (cur_bytes, cur_identity) = match
    find_version_bytes(fixtures, current_version) {
    Some(pair) => pair
    None =>
      return build_response(
        false,
        "Rejected",
        [],
        None,
        0L,
        [],
        "POLICY_REJECTED",
        "UnknownVersion",
        "Requested current_version is outside 1..4.",
        "UnknownVersion(\{current_version})",
      )
  }
  let apply_limits = @moonbsdiff.Limits::for_apply()
  let plan_res = match (effective_max_steps, max_download_opt) {
    (Some(ms), Some(mb)) =>
      verified_catalog.plan_update(
        current_version,
        cur_identity,
        target_version,
        apply_limits,
        max_steps=ms,
        max_download_bytes=mb,
        allow_full=effective_allow_full,
      )
    (Some(ms), None) =>
      verified_catalog.plan_update(
        current_version,
        cur_identity,
        target_version,
        apply_limits,
        max_steps=ms,
        allow_full=effective_allow_full,
      )
    (None, Some(mb)) =>
      verified_catalog.plan_update(
        current_version,
        cur_identity,
        target_version,
        apply_limits,
        max_download_bytes=mb,
        allow_full=effective_allow_full,
      )
    (None, None) =>
      verified_catalog.plan_update(
        current_version,
        cur_identity,
        target_version,
        apply_limits,
        allow_full=effective_allow_full,
      )
  }

  let plan = match plan_res {
    Ok(p) => p
    Err(err) => {
      let code = catalog_error_code(err)
      let status = match err {
        @manifest.CatalogError::DowngradeRejected(..) => "BLOCKED"
        _ => "POLICY_REJECTED"
      }
      let summary = match err {
        @manifest.CatalogError::DowngradeRejected(..) =>
          "Signed catalog verified, then anti-downgrade guard blocked target_version < min_version / current_version."
        @manifest.CatalogError::BudgetExceeded(..) =>
          "Minimum download bytes exceed configured max_download_bytes budget."
        @manifest.CatalogError::NoRoute(..) =>
          "No patch route within max_steps limit and allow_full fallback is disabled."
        _ => "Update planning rejected: " + code
      }
      return build_response(
        false,
        "Rejected",
        [],
        None,
        0L,
        [],
        status,
        code,
        summary,
        @debug.to_string(err),
      )
    }
  }

  // Step 3: Execute the planned decision using REAL @manifest.apply per hop!
  match plan {
    @manifest.CatalogUpdatePlan::UpToDate(rel) =>
      build_response(
        true,
        "UpToDate",
        [],
        None,
        0L,
        [],
        "VERIFIED",
        "UpToDate",
        "Device already matches signed release " +
        rel.label +
        " (0 bytes needed).",
        "",
      )
    @manifest.CatalogUpdatePlan::FullFile(rel) =>
      build_response(
        true,
        "FullFile",
        [],
        None,
        rel.content.size,
        [],
        "VERIFIED",
        "FullFile",
        "Policy selected verified full-file download for " + rel.label + ".",
        "",
      )
    @manifest.CatalogUpdatePlan::Patches(route) => {
      let active_indices : Array[Int32] = []
      for idx in route.patch_indices {
        active_indices.push(idx)
      }
      let steps_json : Array[@json.Json] = []
      let mut running_bytes = cur_bytes
      for hop_i = 0; hop_i < active_indices.length(); hop_i = hop_i + 1 {
        let edge_idx = active_indices[hop_i]
        let edge = fixtures.edges[edge_idx]
        let input_sha = @manifest_support.sha256_hex(running_bytes)
        let deliver_patch = if attack_mode == "tamper_hop" && hop_i == 0 {
          // Simulate CDN bit-flip tampering inside first hop payload.
          flip_byte_at(edge.bundle.patch, edge.bundle.patch.length() / 2)
        } else {
          edge.bundle.patch
        }
        let delivered_patch_sha = @manifest_support.sha256_hex(deliver_patch)
        match
          @manifest.apply(
            running_bytes,
            deliver_patch,
            edge.bundle.manifest,
            apply_limits,
          ) {
          Ok(next_bytes) => {
            let restored_sha = @manifest_support.sha256_hex(next_bytes)
            steps_json.push(
              j_obj({
                "step": j_int(hop_i + 1),
                "from_version": j_i64(edge.from_version),
                "to_version": j_i64(edge.to_version),
                "patch_bytes": j_i64(deliver_patch.length().to_int64()),
                "restored_bytes": j_i64(next_bytes.length().to_int64()),
                "input_sha256": j_str(input_sha),
                "patch_sha256": j_str(delivered_patch_sha),
                "restored_sha256": j_str(restored_sha),
                "verified": j_bool(true),
                "error": j_null(),
              }),
            )
            running_bytes = next_bytes
          }
          Err(err) => {
            let code = manifest_error_code(err)
            let raw = @debug.to_string(err)
            steps_json.push(
              j_obj({
                "step": j_int(hop_i + 1),
                "from_version": j_i64(edge.from_version),
                "to_version": j_i64(edge.to_version),
                "patch_bytes": j_i64(deliver_patch.length().to_int64()),
                "restored_bytes": j_i64(0L),
                "input_sha256": j_str(input_sha),
                "patch_sha256": j_str(delivered_patch_sha),
                "restored_sha256": j_null(),
                "verified": j_bool(false),
                "error": j_str(raw),
              }),
            )
            return build_response(
              false,
              "Rejected",
              active_indices,
              Some(edge_idx),
              route.total_patch_bytes,
              steps_json,
              "BLOCKED",
              code,
              "Hop patch payload failed SHA-256 identity check BEFORE apply — zero corrupted output delivered.",
              raw,
            )
          }
        }
      }
      // Confirm final restored bytes match signed catalog target SHA-256.
      let final_sha = @manifest_support.sha256_hex(running_bytes)
      let ok_final = final_sha == route.target.content.hash
      let summary = if attack_mode == "key_rotation" {
        "Zero-downtime Ed25519 key rotation succeeded via newly rotated key " +
        verified_catalog.signer_key_id +
        "; every hop verified byte-for-byte."
      } else {
        "Ed25519 catalog verified, Dijkstra selected optimal " +
        "\{active_indices.length()}-hop route, and every restored hop matched signed SHA-256."
      }
      build_response(
        ok_final,
        "Patches",
        active_indices,
        None,
        route.total_patch_bytes,
        steps_json,
        if ok_final {
          "VERIFIED"
        } else {
          "BLOCKED"
        },
        if ok_final {
          "VerifiedRoute"
        } else {
          "FinalHashMismatch"
        },
        summary,
        "",
      )
    }
  }
}
