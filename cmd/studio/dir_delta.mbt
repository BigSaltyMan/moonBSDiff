///|
fn build_mini_app_preset() -> (
  Array[@manifest.DirFileEntry],
  Array[@manifest.DirFileEntry],
) {
  let logo_svg = @utf8.encode(
    ("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 120 120'>" +
    "<rect width='120' height='120' rx='24' fill='#0f172a'/>" +
    "<path d='M24 84 L60 24 L96 84 Z' fill='#38bdf8'/>" +
    "<!-- MoonBSDiff Studio Deterministic Asset Padding " +
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef -->" +
    "</svg>")[:],
  )
  let theme_css = @utf8.encode(
    (":root{--bg:#0b1120;--panel:#111827;--accent:#38bdf8;--ok:#34d399;}" +
    "body{margin:0;background:var(--bg);color:#e2e8f0;font-family:monospace;}" +
    "/* padding-block-for-realistic-size-comparison-0123456789abcdef */")[:],
  )
  let font_woff2 = Bytes::from_array(structured_firmware_image(3072, 0x5501U))

  let wasm_v1_arr = structured_firmware_image(8192, 0x5601U)
  let wasm_v2_arr = mutate_slice(wasm_v1_arr, 1024, prng_bytes(40, 0x5602U))
  let wasm_v2_arr2 = mutate_slice(wasm_v2_arr, 5120, b"WASM-RUNTIME-V2.0.0!")

  let worker_v1_arr = structured_firmware_image(5120, 0x5701U)
  let worker_v2_arr = mutate_slice(worker_v1_arr, 2048, prng_bytes(48, 0x5702U))

  // Small config edit where full file (< 60 B) beats BSDIFF40 envelope -> automatic full_fallback!
  let flags_v1 = @utf8.encode("{\"stream_window\":4096,\"verify\":true}\n"[:])
  let flags_v2 = @utf8.encode(
    "{\"stream_window\":4096,\"verify\":true,\"v\":2}\n"[:],
  )

  let release_notes = @utf8.encode(
    ("# MoonApp v2.0.0 Release Notes\n\n" +
    "- Upgraded Wasm runtime with bounded stream verifier.\n" +
    "- Renamed bundled monospace font asset with zero-byte transfer.\n" +
    "- Removed deprecated v1 compatibility layer.\n" +
    "- Signed directory delta manifest with Ed25519.\n")[:],
  )
  let legacy_dat = prng_bytes(2048, 0x5801U)

  let old_files : Array[@manifest.DirFileEntry] = [
    { path: "assets/logo.svg", bytes: logo_svg, },
    { path: "assets/theme.css", bytes: theme_css, },
    { path: "assets/fonts/mono-v1.woff2", bytes: font_woff2, },
    { path: "bin/runtime.wasm", bytes: Bytes::from_array(wasm_v1_arr), },
    { path: "bin/worker.js", bytes: Bytes::from_array(worker_v1_arr), },
    { path: "config/flags.json", bytes: flags_v1, },
    { path: "legacy/compat-v1.dat", bytes: legacy_dat, },
  ]
  let new_files : Array[@manifest.DirFileEntry] = [
    { path: "assets/logo.svg", bytes: logo_svg, },
    { path: "assets/theme.css", bytes: theme_css, },
    { path: "assets/fonts/mono-v2.woff2", bytes: font_woff2, },
    { path: "bin/runtime.wasm", bytes: Bytes::from_array(wasm_v2_arr2), },
    { path: "bin/worker.js", bytes: Bytes::from_array(worker_v2_arr), },
    { path: "config/flags.json", bytes: flags_v2, },
    { path: "docs/release-notes.md", bytes: release_notes, },
  ]
  (old_files, new_files)
}

///|
const DIR_MAX_FILES : Int32 = 256

///|
const DIR_MAX_FILE_BYTES : Int32 = 262144

///|
const DIR_MAX_TOTAL_BYTES : Int64 = 4194304L

///|
fn dir_error_json(
  mode : String,
  preset_name : String,
  tamper_mode : String,
  error_type : String,
  detail : String,
  raw_error : String,
) -> String {
  j_obj({
    "ok": j_bool(false),
    "mode": j_str(mode),
    "preset": j_str(preset_name),
    "tamper_mode": j_str(tamper_mode),
    "signer_key_id": j_null(),
    "trusted_key_ids": j_arr([]),
    "signature_verified": j_bool(false),
    "restored_verified": j_bool(false),
    "old_tree_sha256": j_null(),
    "new_tree_sha256": j_null(),
    "restored_tree_sha256": j_null(),
    "summary": j_null(),
    "entries": j_arr([]),
    "blobs": j_arr([]),
    "error": j_obj({
      "kind": j_str(error_type),
      "detail": j_str(detail),
      "raw": j_str(raw_error),
    }),
    "security_verdict": j_obj({
      "status": j_str("BLOCKED"),
      "error_type": j_str(error_type),
      "detail": j_str(detail),
      "raw_error": j_str(raw_error),
    }),
    "manifest_json_preview": j_str(""),
  }).stringify()
}

///|
fn parse_dir_file_list(
  value : @json.Json,
  field : String,
) -> Result[Array[@manifest.DirFileEntry], (String, String)] {
  let items = match value {
    @json.Array(arr) => arr
    _ => return Err(("InvalidRequest", field + " must be an array"))
  }
  if items.length() > DIR_MAX_FILES {
    return Err(
      (
        "LimitExceeded",
        field + " exceeds max file count (\{items.length()} > \{DIR_MAX_FILES})",
      ),
    )
  }
  let out : Array[@manifest.DirFileEntry] = []
  let mut total_bytes = 0L
  for i = 0; i < items.length(); i = i + 1 {
    match items[i] {
      @json.Object(obj) => {
        let path = match obj.get("path") {
          Some(@json.String(p)) => p
          _ =>
            return Err(
              ("InvalidRequest", field + "[\{i}].path must be a string"),
            )
        }
        let data_hex = match obj.get("data_hex") {
          Some(@json.String(h)) => h
          _ =>
            return Err(
              ("InvalidRequest", field + "[\{i}].data_hex must be a hex string"),
            )
        }
        let bytes = match
          decode_hex_bytes_bounded(data_hex, DIR_MAX_FILE_BYTES) {
          Ok(b) => b
          Err(("LimitExceeded", _)) =>
            return Err(
              (
                "LimitExceeded",
                field +
                "[\{i}] (\{path}) exceeds max file size (\{DIR_MAX_FILE_BYTES} B)",
              ),
            )
          Err((_, e)) =>
            return Err(("InvalidRequest", field + "[\{i}].data_hex: " + e))
        }
        total_bytes = total_bytes + bytes.length().to_int64()
        if total_bytes > DIR_MAX_TOTAL_BYTES {
          return Err(
            (
              "LimitExceeded",
              field +
              " exceeds max total size (\{total_bytes} B > \{DIR_MAX_TOTAL_BYTES} B)",
            ),
          )
        }
        out.push({ path, bytes, })
      }
      _ => return Err(("InvalidRequest", field + "[\{i}] must be an object"))
    }
  }
  Ok(out)
}

///|
fn forge_dir_signature(
  trusted_key_id : String,
  rogue_sig : @manifest.DirManifestSignature,
) -> @manifest.DirManifestSignature {
  let doc = j_obj({
    "schema": j_int(1),
    "type": j_str("moonbsdiff-dir-manifest-signature"),
    "algorithm": j_str("ed25519"),
    "key_id": j_str(trusted_key_id),
    "dir_manifest_sha256": j_str(rogue_sig.dir_manifest_sha256()),
    "signature": j_str(rogue_sig.signature_hex()),
  })
  let raw = @utf8.encode(doc.stringify()[:])
  @manifest.DirManifestSignature::from_json_bytes(raw).unwrap()
}

///|
fn serialize_dir_entries(
  entries : ReadOnlyArray[@manifest.DirEntryAction],
  old_sizes : Map[String, Int64],
) -> Array[@json.Json] {
  let out : Array[@json.Json] = []
  for entry in entries {
    match entry {
      @manifest.DirEntryAction::Unchanged(path~, identity~) =>
        out.push(
          j_obj({
            "action": j_str("UNCHANGED"),
            "path": j_str(path),
            "from_path": j_str(path),
            "old_bytes": j_i64(identity.size),
            "new_bytes": j_i64(identity.size),
            "payload_bytes": j_i64(0L),
            "savings_bytes": j_i64(identity.size),
            "savings_permille": j_i64(1000L),
            "blob_name": j_null(),
            "full_fallback": j_bool(false),
            "sha256": j_str(identity.hash),
          }),
        )
      @manifest.DirEntryAction::Renamed(path~, from_path~, identity~) =>
        out.push(
          j_obj({
            "action": j_str("RENAMED"),
            "path": j_str(path),
            "from_path": j_str(from_path),
            "old_bytes": j_i64(identity.size),
            "new_bytes": j_i64(identity.size),
            "payload_bytes": j_i64(0L),
            "savings_bytes": j_i64(identity.size),
            "savings_permille": j_i64(1000L),
            "blob_name": j_null(),
            "full_fallback": j_bool(false),
            "sha256": j_str(identity.hash),
          }),
        )
      @manifest.DirEntryAction::Patched(
        path~,
        from_path~,
        old_identity~,
        new_identity~,
        patch_identity~,
        blob_name~
      ) => {
        let saved = if new_identity.size > patch_identity.size {
          new_identity.size - patch_identity.size
        } else {
          0L
        }
        out.push(
          j_obj({
            "action": j_str("PATCHED"),
            "path": j_str(path),
            "from_path": j_str(from_path),
            "old_bytes": j_i64(old_identity.size),
            "new_bytes": j_i64(new_identity.size),
            "payload_bytes": j_i64(patch_identity.size),
            "savings_bytes": j_i64(saved),
            "savings_permille": j_i64(
              permille_saved(new_identity.size, patch_identity.size),
            ),
            "blob_name": j_str(blob_name),
            "full_fallback": j_bool(false),
            "sha256": j_str(new_identity.hash),
          }),
        )
      }
      @manifest.DirEntryAction::Added(
        path~,
        identity~,
        blob_name~,
        full_fallback~
      ) => {
        let old_sz = if full_fallback {
          match old_sizes.get(path) {
            Some(sz) => sz
            None => 0L
          }
        } else {
          0L
        }
        let from_p = if full_fallback && old_sizes.contains(path) {
          j_str(path)
        } else {
          j_null()
        }
        out.push(
          j_obj({
            "action": j_str(
              if full_fallback {
                "FULL_FALLBACK"
              } else {
                "ADDED"
              },
            ),
            "path": j_str(path),
            "from_path": from_p,
            "old_bytes": j_i64(old_sz),
            "new_bytes": j_i64(identity.size),
            "payload_bytes": j_i64(identity.size),
            "savings_bytes": j_i64(0L),
            "savings_permille": j_i64(0L),
            "blob_name": j_str(blob_name),
            "full_fallback": j_bool(full_fallback),
            "sha256": j_str(identity.hash),
          }),
        )
      }
      @manifest.DirEntryAction::Deleted(path~, old_identity~) =>
        out.push(
          j_obj({
            "action": j_str("DELETED"),
            "path": j_str(path),
            "from_path": j_str(path),
            "old_bytes": j_i64(old_identity.size),
            "new_bytes": j_i64(0L),
            "payload_bytes": j_i64(0L),
            "savings_bytes": j_i64(0L),
            "savings_permille": j_i64(0L),
            "blob_name": j_null(),
            "full_fallback": j_bool(false),
            "sha256": j_str(old_identity.hash),
          }),
        )
    }
  }
  out
}

///|
fn dir_summary_to_json(summary : @manifest.DirDeltaSummary) -> @json.Json {
  let savings_bytes = if summary.new_total_bytes > summary.delta_payload_bytes {
    summary.new_total_bytes - summary.delta_payload_bytes
  } else {
    0L
  }
  j_obj({
    "unchanged_count": j_int(summary.unchanged_count),
    "renamed_count": j_int(summary.renamed_count),
    "patched_count": j_int(summary.patched_count),
    "added_count": j_int(summary.added_count),
    "full_fallback_count": j_int(summary.full_fallback_count),
    "deleted_count": j_int(summary.deleted_count),
    "old_total_bytes": j_i64(summary.old_total_bytes),
    "new_total_bytes": j_i64(summary.new_total_bytes),
    "delta_payload_bytes": j_i64(summary.delta_payload_bytes),
    "savings_bytes": j_i64(savings_bytes),
    "savings_permille": j_i64(
      permille_saved(summary.new_total_bytes, summary.delta_payload_bytes),
    ),
  })
}

///|
fn run_dir_delta_impl(request_json : String) -> String {
  if !js_is_string(request_json) {
    let msg = "request_json must be a string"
    return dir_error_json(
      "preset", "mini_app_v1_to_v2", "none", "InvalidRequest", msg, msg,
    )
  }
  let fields = match parse_json_object_or_empty(request_json) {
    Ok(f) => f
    Err(msg) =>
      return dir_error_json(
        "preset", "mini_app_v1_to_v2", "none", "InvalidRequest", msg, msg,
      )
  }
  let tamper_mode = get_opt_string(fields, "tamper_mode", "none")
  let preset_name = get_opt_string(fields, "preset", "mini_app_v1_to_v2")
  let (mode, old_files, new_files) = match
    (fields.get("old_files"), fields.get("new_files")) {
    (None, None)
    | (Some(@json.Null), None)
    | (None, Some(@json.Null))
    | (Some(@json.Null), Some(@json.Null)) => {
      if preset_name != "mini_app_v1_to_v2" {
        let msg = "unknown dir preset: " + preset_name
        return dir_error_json(
          "preset", preset_name, tamper_mode, "UnknownPreset", msg, msg,
        )
      }
      let (o, n) = build_mini_app_preset()
      ("preset", o, n)
    }
    (Some(old_val), Some(new_val)) => {
      let old_list = match parse_dir_file_list(old_val, "old_files") {
        Ok(v) => v
        Err((code, msg)) =>
          return dir_error_json(
            "custom", preset_name, tamper_mode, code, msg, msg,
          )
      }
      let new_list = match parse_dir_file_list(new_val, "new_files") {
        Ok(v) => v
        Err((code, msg)) =>
          return dir_error_json(
            "custom", preset_name, tamper_mode, code, msg, msg,
          )
      }
      ("custom", old_list, new_list)
    }
    (Some(_), _) => {
      let msg = "custom directory delta requires both old_files and new_files (missing new_files)"
      return dir_error_json(
        "custom", preset_name, tamper_mode, "InvalidRequest", msg, msg,
      )
    }
    (_, Some(_)) => {
      let msg = "custom directory delta requires both old_files and new_files (missing old_files)"
      return dir_error_json(
        "custom", preset_name, tamper_mode, "InvalidRequest", msg, msg,
      )
    }
  }

  let (sk, pk) = studio_keypair(1)
  let diff_limits : @moonbsdiff.Limits = {
    ..@moonbsdiff.Limits::for_diff(),
    max_old_bytes: 262144L,
    max_new_bytes: 262144L,
    max_output_bytes: 262144L,
    max_patch_bytes: 262144L,
    max_decompressed_bytes: 524288L,
  }
  let apply_limits : @moonbsdiff.Limits = {
    ..@moonbsdiff.Limits::for_apply(),
    max_patch_bytes: 262144L,
  }

  // Compute baseline clean bundle so the explorer can always render file-level breakdown.
  let clean_bundle = match
    @manifest.dir_diff(old_files, new_files, diff_limits) {
    Ok(b) => b
    Err(err) => {
      let code = dir_delta_error_code(err)
      let raw = @debug.to_string(err)
      return j_obj({
        "ok": j_bool(false),
        "mode": j_str(mode),
        "preset": j_str(preset_name),
        "tamper_mode": j_str(tamper_mode),
        "signer_key_id": j_str(pk.key_id()),
        "trusted_key_ids": j_arr([j_str(pk.key_id())]),
        "signature_verified": j_bool(false),
        "restored_verified": j_bool(false),
        "old_tree_sha256": j_null(),
        "new_tree_sha256": j_null(),
        "restored_tree_sha256": j_null(),
        "summary": j_null(),
        "entries": j_arr([]),
        "blobs": j_arr([]),
        "security_verdict": j_obj({
          "status": j_str("BLOCKED"),
          "error_type": j_str(code),
          "detail": j_str("Directory diff rejected input tree: " + code),
          "raw_error": j_str(raw),
        }),
        "manifest_json_preview": j_str(""),
      }).stringify()
    }
  }

  let old_sizes : Map[String, Int64] = Map([])
  for f in old_files {
    old_sizes[f.path] = f.bytes.length().to_int64()
  }
  let base_summary = @manifest.dir_summarize(clean_bundle.manifest)
  let entries_json = serialize_dir_entries(
    clean_bundle.manifest.entries,
    old_sizes,
  )
  let manifest_preview = bytes_to_utf8_lossy(clean_bundle.manifest_bytes)

  // Path traversal red-team test: inject '../escape.sh' and pass straight into @manifest.dir_diff.
  if tamper_mode == "path_traversal" {
    let evil_new : Array[@manifest.DirFileEntry] = []
    for f in new_files {
      evil_new.push(f)
    }
    evil_new.push({ path: "../escape.sh", bytes: b"#!/bin/sh\necho pwned\n", })
    match @manifest.dir_diff(old_files, evil_new, diff_limits) {
      Err(err) => {
        let code = dir_delta_error_code(err)
        let raw = @debug.to_string(err)
        let blobs_json : Array[@json.Json] = []
        for b in clean_bundle.blobs {
          blobs_json.push(
            j_obj({
              "name": j_str(b.name),
              "bytes": j_i64(b.bytes.length().to_int64()),
              "sha256": j_str(@manifest_support.sha256_hex(b.bytes)),
              "tampered": j_bool(false),
            }),
          )
        }
        return j_obj({
          "ok": j_bool(false),
          "mode": j_str(mode),
          "preset": j_str(preset_name),
          "tamper_mode": j_str(tamper_mode),
          "signer_key_id": j_str(pk.key_id()),
          "trusted_key_ids": j_arr([j_str(pk.key_id())]),
          "signature_verified": j_bool(false),
          "restored_verified": j_bool(false),
          "old_tree_sha256": j_str(base_summary.old_tree_sha256),
          "new_tree_sha256": j_str(base_summary.new_tree_sha256),
          "restored_tree_sha256": j_null(),
          "summary": dir_summary_to_json(base_summary),
          "entries": j_arr(entries_json),
          "blobs": j_arr(blobs_json),
          "security_verdict": j_obj({
            "status": j_str("BLOCKED"),
            "error_type": j_str(code),
            "detail": j_str(
              "Strict POSIX relative-path validator blocked '../escape.sh' before bundle generation or extraction.",
            ),
            "raw_error": j_str(raw),
          }),
          "manifest_json_preview": j_str(manifest_preview),
        }).stringify()
      }
      Ok(_) => ()
    }
  }

  let real_sig = sk.sign_dir_manifest(clean_bundle.manifest_bytes).unwrap()
  let effective_sig = if tamper_mode == "forged_signature" {
    let (sk_rogue, _) = studio_keypair(3)
    let rogue_sig = sk_rogue
      .sign_dir_manifest(clean_bundle.manifest_bytes)
      .unwrap()
    forge_dir_signature(pk.key_id(), rogue_sig)
  } else {
    real_sig
  }

  let blobs_arr : Array[@manifest.DirBlob] = []
  let blobs_json : Array[@json.Json] = []
  let mut tampered_one = false
  for b in clean_bundle.blobs {
    let should_tamper = tamper_mode == "tamper_blob" && !tampered_one
    let effective_bytes = if should_tamper {
      tampered_one = true
      tamper_bytes(b.bytes)
    } else {
      b.bytes
    }
    blobs_arr.push({ name: b.name, bytes: effective_bytes, })
    blobs_json.push(
      j_obj({
        "name": j_str(b.name),
        "bytes": j_i64(effective_bytes.length().to_int64()),
        "sha256": j_str(@manifest_support.sha256_hex(effective_bytes)),
        "tampered": j_bool(should_tamper),
      }),
    )
  }
  if tamper_mode == "tamper_blob" && !tampered_one {
    let bogus_name = "tampered-unexpected.blob"
    let bogus_bytes = b"\x55"
    blobs_arr.push({ name: bogus_name, bytes: bogus_bytes, })
    blobs_json.push(
      j_obj({
        "name": j_str(bogus_name),
        "bytes": j_i64(bogus_bytes.length().to_int64()),
        "sha256": j_str(@manifest_support.sha256_hex(bogus_bytes)),
        "tampered": j_bool(true),
      }),
    )
  }

  match
    @manifest.dir_apply_signed(
      old_files,
      clean_bundle.manifest_bytes,
      effective_sig,
      [pk],
      blobs_arr,
      apply_limits,
    ) {
    Ok((restored_files, applied_summary, verified_key)) => {
      let restored_tree = @manifest.tree_sha256(restored_files).unwrap()
      let tree_ok = restored_tree == applied_summary.new_tree_sha256
      j_obj({
        "ok": j_bool(tree_ok),
        "mode": j_str(mode),
        "preset": j_str(preset_name),
        "tamper_mode": j_str(tamper_mode),
        "signer_key_id": j_str(verified_key.key_id()),
        "trusted_key_ids": j_arr([j_str(pk.key_id())]),
        "signature_verified": j_bool(true),
        "restored_verified": j_bool(tree_ok),
        "old_tree_sha256": j_str(applied_summary.old_tree_sha256),
        "new_tree_sha256": j_str(applied_summary.new_tree_sha256),
        "restored_tree_sha256": j_str(restored_tree),
        "summary": dir_summary_to_json(applied_summary),
        "entries": j_arr(entries_json),
        "blobs": j_arr(blobs_json),
        "security_verdict": j_obj({
          "status": j_str(if tree_ok { "VERIFIED" } else { "BLOCKED" }),
          "error_type": j_str(
            if tree_ok {
              "VerifiedDirBundle"
            } else {
              "NewTreeMismatch"
            },
          ),
          "detail": j_str(
            "Ed25519 manifest signature verified, every blob/patch authenticated, and restored tree_sha256 matched exactly.",
          ),
          "raw_error": j_str(""),
        }),
        "manifest_json_preview": j_str(manifest_preview),
      }).stringify()
    }
    Err(err) => {
      let code = dir_delta_error_code(err)
      let raw = @debug.to_string(err)
      let sig_ok = match err {
        @manifest.DirDeltaError::Signature(_) => false
        _ => true
      }
      let detail = match err {
        @manifest.DirDeltaError::Signature(_) =>
          "Ed25519 signature rejected BEFORE manifest parsing or blob inspection — fail-closed!"
        @manifest.DirDeltaError::IdentityMismatch(..) =>
          "Signed manifest passed, then tampered blob SHA-256 mismatch aborted apply before restoring!"
        @manifest.DirDeltaError::UnexpectedBlob(_) =>
          "Signed manifest referenced zero payload blobs; injected unexpected blob was blocked before restoring!"
        _ => "Signed directory apply rejected: " + code
      }
      j_obj({
        "ok": j_bool(false),
        "mode": j_str(mode),
        "preset": j_str(preset_name),
        "tamper_mode": j_str(tamper_mode),
        "signer_key_id": j_str(effective_sig.key_id()),
        "trusted_key_ids": j_arr([j_str(pk.key_id())]),
        "signature_verified": j_bool(sig_ok),
        "restored_verified": j_bool(false),
        "old_tree_sha256": j_str(base_summary.old_tree_sha256),
        "new_tree_sha256": j_str(base_summary.new_tree_sha256),
        "restored_tree_sha256": j_null(),
        "summary": dir_summary_to_json(base_summary),
        "entries": j_arr(entries_json),
        "blobs": j_arr(blobs_json),
        "security_verdict": j_obj({
          "status": j_str("BLOCKED"),
          "error_type": j_str(code),
          "detail": j_str(detail),
          "raw_error": j_str(raw),
        }),
        "manifest_json_preview": j_str(manifest_preview),
      }).stringify()
    }
  }
}
