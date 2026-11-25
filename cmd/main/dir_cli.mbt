///|
extern "C" fn io_is_windows() -> Int32 = "mbsd_is_windows"

///|
#borrow(utf8)
extern "C" fn io_case_fold_utf8(utf8 : Bytes) -> Bytes = "mbsd_case_fold_utf8"

///|
#borrow(output_dir)
extern "C" fn io_parent_is_case_insensitive(output_dir : Bytes) -> Int32 = "mbsd_parent_is_case_insensitive"

///|
#borrow(input_dir, output_dir)
extern "C" fn io_dir_output_check(
  input_dir : Bytes,
  output_dir : Bytes,
) -> Int32 = "mbsd_dir_output_check"

///|
#borrow(dir_path)
extern "C" fn io_dir_list(dir_path : Bytes) -> Bytes = "mbsd_dir_list"

///|
#borrow(root_dir, rel_subdir)
extern "C" fn io_dir_list_flat(root_dir : Bytes, rel_subdir : Bytes) -> Bytes = "mbsd_dir_list_flat"

///|
#borrow(root_dir, rel_path)
extern "C" fn io_read_rel_nosymlink(
  root_dir : Bytes,
  rel_path : Bytes,
  cap : Int32,
) -> Bytes = "mbsd_read_rel_nosymlink"

///|
#borrow(dir_path)
extern "C" fn io_dir_exists_nosymlink(dir_path : Bytes) -> Int32 = "mbsd_dir_exists_nosymlink"

///|
#borrow(dir_path)
extern "C" fn io_mkdir_new(dir_path : Bytes) -> Int32 = "mbsd_mkdir_new"

///|
#borrow(root_dir, rel_path)
extern "C" fn io_mkdir_parents(root_dir : Bytes, rel_path : Bytes) -> Int32 = "mbsd_mkdir_parents"

///|
let dir_default_tree_byte_cap : Int64 = 134217728L

///|
fn dir_tree_byte_cap(per_file_cap : Int64) -> Int64 {
  Int64::max(dir_default_tree_byte_cap, per_file_cap)
}

///|
fn dir_delta_diagnostic(err : @manifest.DirDeltaError) -> String {
  match err {
    InvalidPath(path~, detail~) => "invalid path '\{path}': " + detail
    DuplicatePath(path) => "duplicate path: '\{path}'"
    PathCollision(a~, b~) => "path collision between '\{a}' and '\{b}'"
    InvalidBlobName(name~, detail~) => "invalid blob name '\{name}': " + detail
    DuplicateBlob(name) => "duplicate blob: '\{name}'"
    MissingBlob(name) => "missing required blob: '\{name}'"
    UnexpectedBlob(name) => "unexpected unreferenced blob: '\{name}'"
    InvalidLimits(reason) => @debug.to_string(reason)
    LimitExceeded(field~, value~, limit~) =>
      "dir bundle limit \{field} value \{value} exceeds limit \{limit}"
    InvalidEncoding => "dir manifest encoding: expected valid UTF-8 without BOM"
    InvalidJson(detail~, ..) => "dir manifest JSON: " + detail
    InvalidSchema(detail~, ..) => detail
    OldTreeMismatch(expected~, actual~) =>
      "old_tree_sha256 mismatch: expected \{expected}, got \{actual}"
    NewTreeMismatch(expected~, actual~) =>
      "new_tree_sha256 mismatch: expected \{expected}, got \{actual}"
    MissingOldFile(path~) => "missing old file: '\{path}'"
    IdentityMismatch(path~, object~, difference~) => {
      let obj_name = match object {
        Old => "old file"
        Patch => "patch blob"
        PatchTarget => "patch header/new"
        Restored => "restored file"
      }
      match difference {
        Size(expected~, actual~) =>
          "\{obj_name} '\{path}' size mismatch: expected \{expected}, got \{actual}"
        Sha256 => "\{obj_name} '\{path}' sha256 mismatch"
      }
    }
    ApplyError(path~, error~) =>
      "apply patch for '\{path}': " + @debug.to_string(error)
    Signature(sig_err) => signature_diagnostic(sig_err)
  }
}

///|
fn replace_slash_with_backslash(s : String) -> String {
  let sb = StringBuilder(size_hint=s.length())
  for ch in s {
    if ch == '/' {
      sb.write_char('\\')
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
fn join_child_path(base : String, rel : String) -> String {
  let is_win = io_is_windows() != 0
  let child = if is_win { replace_slash_with_backslash(rel) } else { rel }
  let len = base.length()
  if len == 0 {
    return child
  }
  let last = base.code_unit_at(len - 1)
  if is_win {
    if last == 47 || last == 92 {
      base + child
    } else {
      base + "\\" + child
    }
  } else if last == 47 {
    base + child
  } else {
    base + "/" + child
  }
}

///|
fn check_dir_output_against(
  dir_inputs : Array[String],
  all_inputs : Array[String],
  output_dir : String,
) -> Bool {
  if !check_output_against(all_inputs, output_dir) {
    return false
  }
  let out_bytes = path_bytes(output_dir)
  for inp in dir_inputs {
    if io_dir_output_check(path_bytes(inp), out_bytes) == 0 {
      return false
    }
  }
  true
}

///|
fn fold_case_path(op : String, s : String) -> String {
  let folded = io_case_fold_utf8(@utf8.encode(s[:]))
  if io_failed() != 0 {
    failure("\{op} fold path '\{s}': " + @utf8.decode_lossy(io_error()[:]))
    abort("unreachable after process exit")
  }
  @utf8.decode(folded[:], ignore_bom=false) catch {
    _ => {
      failure("\{op} fold path '\{s}': invalid UTF-8")
      abort("unreachable after process exit")
    }
  }
}

///|
fn ascii_to_upper(s : String) -> String {
  let sb = StringBuilder(size_hint=s.length())
  for ch in s {
    let c = ch.to_int()
    if c >= 97 && c <= 122 {
      sb.write_char((c - 32).unsafe_to_char())
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
fn split_rel_segments(path : String) -> Array[String] {
  let parts : Array[String] = []
  let mut sb = StringBuilder()
  for ch in path {
    if ch == '/' {
      parts.push(sb.to_string())
      sb = StringBuilder()
    } else {
      sb.write_char(ch)
    }
  }
  parts.push(sb.to_string())
  parts
}

///|
fn is_win_dos_device_name(seg : String) -> Bool {
  let stem_chars : Array[Char] = []
  for ch in seg {
    if ch == '.' {
      break
    }
    let c = ch.to_int()
    if c > 127 && c != 0x00B9 && c != 0x00B2 && c != 0x00B3 {
      return false
    }
    stem_chars.push(ch)
  }
  while stem_chars.length() > 0 && stem_chars[stem_chars.length() - 1] == ' ' {
    stem_chars.pop() |> ignore
  }
  let sb = StringBuilder(size_hint=stem_chars.length())
  for ch in stem_chars {
    sb.write_char(ch)
  }
  match ascii_to_upper(sb.to_string()) {
    "CON"
    | "CONIN$"
    | "CONOUT$"
    | "PRN"
    | "AUX"
    | "NUL"
    | "COM0"
    | "COM1"
    | "COM2"
    | "COM3"
    | "COM4"
    | "COM5"
    | "COM6"
    | "COM7"
    | "COM8"
    | "COM9"
    | "COM\u{00B9}"
    | "COM\u{00B2}"
    | "COM\u{00B3}"
    | "LPT0"
    | "LPT1"
    | "LPT2"
    | "LPT3"
    | "LPT4"
    | "LPT5"
    | "LPT6"
    | "LPT7"
    | "LPT8"
    | "LPT9"
    | "LPT\u{00B9}"
    | "LPT\u{00B2}"
    | "LPT\u{00B3}" => true
    _ => false
  }
}

///|
fn validate_win_segment(seg : String) -> String? {
  let len = seg.length()
  if len == 0 {
    return Some("empty path segment")
  }
  let last = seg.code_unit_at(len - 1)
  if last == 46 || last == 32 {
    return Some("trailing dot or space is unsupported on Windows")
  }
  for ch in seg {
    if ch == ':' {
      return Some("colon is unsupported in Windows path segments")
    }
    if ch == '<' ||
      ch == '>' ||
      ch == '"' ||
      ch == '|' ||
      ch == '?' ||
      ch == '*' {
      return Some("reserved Windows filename character")
    }
  }
  if is_win_dos_device_name(seg) {
    return Some("reserved Windows DOS device name")
  }
  None
}

///|
fn preflight_restored_paths(
  op : String,
  output_dir : String,
  restored : Array[@manifest.DirFileEntry],
) -> Unit {
  let is_win = io_is_windows() != 0
  let ci_flag = io_parent_is_case_insensitive(path_bytes(output_dir))
  if ci_flag < 0 {
    failure(
      "\{op} output '\{output_dir}': " + @utf8.decode_lossy(io_error()[:]),
    )
    abort("unreachable after process exit")
  }
  let case_insensitive = ci_flag != 0
  let folded_files : Map[String, String] = Map([])
  let folded_dirs : Map[String, String] = Map([])
  for entry in restored {
    match @manifest.validate_relative_path(entry.path) {
      Ok(_) => ()
      Err(err) => {
        failure("\{op}: " + dir_delta_diagnostic(err))
        abort("unreachable after process exit")
      }
    }
    let segs = split_rel_segments(entry.path)
    if is_win {
      for seg in segs {
        if validate_win_segment(seg) is Some(reason) {
          failure(
            "\{op}: unsafe Windows path segment '\{seg}' in '\{entry.path}': \{reason}",
          )
          abort("unreachable after process exit")
        }
      }
    }
    if case_insensitive {
      let folded_path = fold_case_path(op, entry.path)
      if folded_files.get(folded_path) is Some(prev) {
        failure(
          "\{op}: case-insensitive path collision between '\{prev}' and '\{entry.path}'",
        )
        abort("unreachable after process exit")
      }
      folded_files[folded_path] = entry.path
      if segs.length() > 1 {
        let mut prefix = segs[0]
        for idx = 0; idx < segs.length() - 1; idx = idx + 1 {
          if idx > 0 {
            prefix = prefix + "/" + segs[idx]
          }
          let folded_prefix = fold_case_path(op, prefix)
          if folded_dirs.get(folded_prefix) is Some(prev_dir) &&
            prev_dir != prefix {
            failure(
              "\{op}: case-insensitive directory collision between '\{prev_dir}' and '\{prefix}'",
            )
            abort("unreachable after process exit")
          }
          folded_dirs[folded_prefix] = prefix
        }
      }
    }
  }
  if case_insensitive {
    for folded_path, orig_path in folded_files {
      if folded_dirs.get(folded_path) is Some(dir_prefix) {
        failure(
          "\{op}: case-insensitive file/directory collision between '\{orig_path}' and '\{dir_prefix}/...'",
        )
        abort("unreachable after process exit")
      }
    }
  }
}

///|
fn parse_dir_listing(
  op : String,
  label : String,
  dir_path : String,
  raw : Bytes,
) -> Array[String] {
  let paths : Array[String] = []
  let len = raw.length()
  if len == 0 {
    return paths
  }
  let mut start = 0
  for i = 0; i <= len; i = i + 1 {
    if i == len || raw[i] == b'\n' {
      let item = @utf8.decode(raw[start:i], ignore_bom=false) catch {
        _ => {
          failure("\{op} list \{label} directory '\{dir_path}': invalid UTF-8")
          abort("unreachable after process exit")
        }
      }
      match @manifest.validate_relative_path(item) {
        Ok(_) => paths.push(item)
        Err(err) => {
          failure(
            "\{op} \{label} directory '\{dir_path}': " +
            dir_delta_diagnostic(err),
          )
          abort("unreachable after process exit")
        }
      }
      start = i + 1
    }
  }
  paths
}

///|
fn list_dir_paths(
  op : String,
  label : String,
  dir_path : String,
) -> Array[String] {
  let raw = io_dir_list(path_bytes(dir_path))
  if io_failed() != 0 {
    failure(
      "\{op} list \{label} directory '\{dir_path}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    abort("unreachable after process exit")
  }
  parse_dir_listing(op, label, dir_path, raw)
}

///|
fn list_blobs_flat(op : String, bundle_dir : String) -> Array[String] {
  let raw = io_dir_list_flat(path_bytes(bundle_dir), path_bytes("blobs"))
  if io_failed() != 0 {
    failure(
      "\{op} blobs directory in '\{bundle_dir}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    abort("unreachable after process exit")
  }
  parse_dir_listing(op, "blobs", join_child_path(bundle_dir, "blobs"), raw)
}

///|
fn read_rel_input(
  context : String,
  root_dir : String,
  rel_path : String,
  cap : Int64,
) -> Bytes {
  let data = io_read_rel_nosymlink(
    path_bytes(root_dir),
    path_bytes(rel_path),
    cap.to_int(),
  )
  if io_failed() != 0 {
    failure(
      "\{context} '\{rel_path}' in '\{root_dir}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    abort("unreachable after process exit")
  }
  data
}

///|
fn read_dir_tree_paths(
  op : String,
  label : String,
  dir_path : String,
  rel_paths : Array[String],
  file_cap : Int64,
  tree_cap : Int64,
) -> Array[@manifest.DirFileEntry] {
  let entries : Array[@manifest.DirFileEntry] = []
  let mut total_read = 0L
  for rel in rel_paths {
    let remaining = tree_cap - total_read
    let read_cap = Int64::min(file_cap, remaining)
    let data = io_read_rel_nosymlink(
      path_bytes(dir_path),
      path_bytes(rel),
      read_cap.to_int(),
    )
    if io_failed() != 0 {
      let err = @utf8.decode_lossy(io_error()[:])
      if remaining < file_cap && err.contains("byte limit") {
        failure(
          "\{op} read \{label} file '\{rel}' in '\{dir_path}': cumulative \{label} tree size exceeds limit \{tree_cap} bytes",
        )
      } else {
        failure(
          "\{op} read \{label} file '\{rel}' (limit=\{file_cap} bytes) in '\{dir_path}': \{err}",
        )
      }
      abort("unreachable after process exit")
    }
    total_read += data.length().to_int64()
    entries.push({ path: rel, bytes: data, })
  }
  entries
}

///|
fn read_dir_tree(
  op : String,
  label : String,
  dir_path : String,
  file_cap : Int64,
) -> Array[@manifest.DirFileEntry] {
  let rel_paths = list_dir_paths(op, label, dir_path)
  read_dir_tree_paths(
    op,
    label,
    dir_path,
    rel_paths,
    file_cap,
    dir_tree_byte_cap(file_cap),
  )
}

///|
fn check_dir_manifest_limit(
  op : String,
  field : String,
  value : Int64,
  limit : Int64,
) -> Unit {
  if value > limit {
    failure(
      "\{op}: " + dir_delta_diagnostic(LimitExceeded(field~, value~, limit~)),
    )
    abort("unreachable after process exit")
  }
}

///|
fn dir_summary_json_fields(
  operation : String,
  summary : @manifest.DirDeltaSummary,
  signer_key_id : String?,
) -> Map[String, @json.Json] {
  let signer_json = match signer_key_id {
    Some(id) => @json.Json::string(id)
    None => @json.Json::null()
  }
  {
    "schema_version": @json.Json::number(1.0),
    "operation": @json.Json::string(operation),
    "signed": @json.Json::boolean(signer_key_id is Some(_)),
    "signer_key_id": signer_json,
    "unchanged_count": @json.Json::number(summary.unchanged_count.to_double()),
    "renamed_count": @json.Json::number(summary.renamed_count.to_double()),
    "patched_count": @json.Json::number(summary.patched_count.to_double()),
    "added_count": @json.Json::number(summary.added_count.to_double()),
    "full_fallback_count": @json.Json::number(
      summary.full_fallback_count.to_double(),
    ),
    "deleted_count": @json.Json::number(summary.deleted_count.to_double()),
    "old_total_bytes": @json.Json::string("\{summary.old_total_bytes}"),
    "new_total_bytes": @json.Json::string("\{summary.new_total_bytes}"),
    "delta_payload_bytes": @json.Json::string("\{summary.delta_payload_bytes}"),
    "old_tree_sha256": @json.Json::string(summary.old_tree_sha256),
    "new_tree_sha256": @json.Json::string(summary.new_tree_sha256),
  }
}

///|
fn print_dir_summary_text(
  title : String,
  summary : @manifest.DirDeltaSummary,
  signer_key_id : String?,
) -> Unit {
  println(title)
  match signer_key_id {
    Some(id) => println("Signature: verified/signed (key_id=\{id})")
    None => println("Signature: unsigned")
  }
  println(
    "Counts: unchanged=\{summary.unchanged_count}, renamed=\{summary.renamed_count}, patched=\{summary.patched_count}, added=\{summary.added_count} (full_fallback=\{summary.full_fallback_count}), deleted=\{summary.deleted_count}",
  )
  println(
    "Bytes: old=\{summary.old_total_bytes}, new=\{summary.new_total_bytes}, delta_payload=\{summary.delta_payload_bytes}",
  )
  println("Old tree SHA-256: \{summary.old_tree_sha256}")
  println("New tree SHA-256: \{summary.new_tree_sha256}")
}

///|
fn dir_diff_command(config : CliConfig) -> Unit {
  let op = config.operation
  let old_dir = config.files[0]
  let new_dir = config.files[1]
  let bundle_dir = config.files[2]
  let dir_inputs = [old_dir, new_dir]
  let inputs = [old_dir, new_dir]
  if config.private_key is Some(priv_path) {
    inputs.push(priv_path)
  }
  if !check_dir_output_against(dir_inputs, inputs, bundle_dir) {
    failure(
      "\{op} output '\{bundle_dir}': " + @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  let priv_key : @manifest.PrivateKey? = match config.private_key {
    Some(priv_path) => {
      let priv_bytes = read_input(
        "\{op} read private key (limit=\{@manifest.max_key_file_bytes} bytes)",
        priv_path,
        @manifest.max_key_file_bytes.to_int64(),
      )
      match @manifest.PrivateKey::from_json_bytes(priv_bytes) {
        Ok(k) => Some(k)
        Err(err) => {
          failure("\{op} '\{priv_path}': " + signature_diagnostic(err))
          return
        }
      }
    }
    None => None
  }
  let old_entries = read_dir_tree(
    op,
    "old",
    old_dir,
    config.limits.max_old_bytes,
  )
  let new_entries = read_dir_tree(
    op,
    "new",
    new_dir,
    config.limits.max_new_bytes,
  )
  let bundle = match
    @manifest.dir_diff(old_entries, new_entries, config.limits) {
    Ok(b) => b
    Err(err) => {
      failure("\{op}: " + dir_delta_diagnostic(err))
      return
    }
  }
  let dir_sig : @manifest.DirManifestSignature? = match priv_key {
    Some(pk) =>
      match pk.sign_dir_manifest(bundle.manifest_bytes) {
        Ok(s) => Some(s)
        Err(err) => {
          failure("\{op} sign dir manifest: " + dir_delta_diagnostic(err))
          return
        }
      }
    None => None
  }
  if io_mkdir_new(path_bytes(bundle_dir)) == 0 {
    failure(
      "\{op} create bundle directory '\{bundle_dir}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  let total_blobs = bundle.blobs.length()
  let mut blobs_written = 0
  if total_blobs > 0 {
    let blobs_dir = join_child_path(bundle_dir, "blobs")
    if io_mkdir_new(path_bytes(blobs_dir)) == 0 {
      failure(
        "\{op} create blobs directory '\{blobs_dir}' (bundle directory '\{bundle_dir}' created; delivered 0/\{total_blobs} blobs): " +
        @utf8.decode_lossy(io_error()[:]) +
        "; no rollback attempted",
      )
      return
    }
    for blob in bundle.blobs {
      let blob_path = join_child_path(blobs_dir, blob.name)
      if io_deliver(path_bytes(blob_path), blob.bytes) == 0 {
        let detail = @utf8.decode_lossy(io_error()[:])
        let committed = delivered_output() != 0
        let count = if committed { blobs_written + 1 } else { blobs_written }
        let file_state = if committed {
          "delivered with an error"
        } else {
          "not delivered"
        }
        failure(
          "\{op} write blob '\{blob_path}' (bundle directory '\{bundle_dir}' created; delivered \{count}/\{total_blobs} blobs; current file \{file_state}): \{detail}; no rollback attempted",
        )
        return
      }
      blobs_written = blobs_written + 1
    }
  }
  let manifest_path = join_child_path(bundle_dir, "dir-manifest.json")
  if io_deliver(path_bytes(manifest_path), bundle.manifest_bytes) == 0 {
    let detail = @utf8.decode_lossy(io_error()[:])
    let file_state = if delivered_output() != 0 {
      "delivered with an error"
    } else {
      "not delivered"
    }
    failure(
      "\{op} write '\{manifest_path}' (bundle directory '\{bundle_dir}' created; delivered \{blobs_written}/\{total_blobs} blobs; manifest \{file_state}): \{detail}; no rollback attempted",
    )
    return
  }
  let mut sig_path_opt : String? = None
  let mut signer_key_id : String? = None
  if dir_sig is Some(sig) {
    let sig_path = join_child_path(bundle_dir, "dir-manifest.sig")
    if io_deliver(path_bytes(sig_path), sig.to_json_bytes()) == 0 {
      let detail = @utf8.decode_lossy(io_error()[:])
      let file_state = if delivered_output() != 0 {
        "delivered with an error"
      } else {
        "not delivered"
      }
      failure(
        "\{op} write signature '\{sig_path}' (bundle directory '\{bundle_dir}' created; delivered \{blobs_written}/\{total_blobs} blobs and manifest; signature \{file_state}): \{detail}; no rollback attempted",
      )
      return
    }
    sig_path_opt = Some(sig_path)
    signer_key_id = Some(sig.key_id())
  }
  let summary = @manifest.dir_summarize(bundle.manifest)
  if config.json {
    let fields = dir_summary_json_fields(op, summary, signer_key_id)
    fields["bundle_dir"] = @json.Json::string(bundle_dir)
    fields["manifest_path"] = @json.Json::string(manifest_path)
    fields["blob_count"] = @json.Json::number(bundle.blobs.length().to_double())
    fields["signature_path"] = match sig_path_opt {
      Some(p) => @json.Json::string(p)
      None => @json.Json::null()
    }
    println(@json.Json::object(fields).stringify())
  } else {
    print_dir_summary_text(
      "Directory delta bundle created at '\{bundle_dir}'",
      summary,
      signer_key_id,
    )
  }
}

///|
fn load_and_apply_dir_bundle(
  config : CliConfig,
  old_dir : String,
  bundle_dir : String,
) -> (Array[@manifest.DirFileEntry], @manifest.DirDeltaSummary, String?) {
  let op = config.operation
  let limits = config.limits
  let bcheck = io_dir_exists_nosymlink(path_bytes(bundle_dir))
  if bcheck != 1 {
    let detail = if bcheck == 0 {
      "bundle directory does not exist"
    } else {
      @utf8.decode_lossy(io_error()[:])
    }
    failure("\{op} bundle '\{bundle_dir}': " + detail)
    abort("unreachable after process exit")
  }
  let manifest_bytes = read_rel_input(
    "\{op} read dir manifest (limit=\{@manifest.max_dir_manifest_bytes} bytes)",
    bundle_dir,
    "dir-manifest.json",
    @manifest.max_dir_manifest_bytes.to_int64(),
  )
  // Verify detached signature FIRST before parsing manifest or opening OLD_DIR / blobs/.
  let signer_key_id : String? = if !config.public_keys.is_empty() {
    let (store, _) = match load_trust_store(op, config.public_keys) {
      Ok(v) => v
      Err(msg) => {
        failure(msg)
        abort("unreachable after process exit")
      }
    }
    let dedup_keys : Array[@manifest.PublicKey] = []
    for id in store.key_ids() {
      if store.find(id) is Some(pk) {
        dedup_keys.push(pk)
      }
    }
    let sig_path = config.signature.unwrap()
    let sig_bytes = read_input(
      "\{op} read signature (limit=\{@manifest.max_signature_file_bytes} bytes)",
      sig_path,
      @manifest.max_signature_file_bytes.to_int64(),
    )
    let sig = match @manifest.DirManifestSignature::from_json_bytes(sig_bytes) {
      Ok(s) => s
      Err(err) => {
        failure("\{op} '\{sig_path}': " + signature_diagnostic(err))
        abort("unreachable after process exit")
      }
    }
    match
      @manifest.verify_dir_manifest_signature_with_keys(
        manifest_bytes, sig, dedup_keys,
      ) {
      Ok(verified_key) => Some(verified_key.key_id())
      Err(err) => {
        failure("\{op} signature: " + signature_diagnostic(err))
        abort("unreachable after process exit")
      }
    }
  } else {
    None
  }
  // Parse manifest immediately after optional signature verification, BEFORE touching OLD_DIR or blobs/.
  let manifest = match @manifest.DirManifest::from_json_bytes(manifest_bytes) {
    Ok(m) => m
    Err(err) => {
      failure("\{op}: " + dir_delta_diagnostic(err))
      abort("unreachable after process exit")
    }
  }
  let added_blob_cap = Int64::min(limits.max_new_bytes, limits.max_output_bytes)
  let expected_blob_caps : Map[String, Int64] = Map([])
  for entry in manifest.entries {
    match entry {
      Unchanged(identity~, ..) | Renamed(identity~, ..) => {
        check_dir_manifest_limit(
          op,
          "max_old_bytes",
          identity.size,
          limits.max_old_bytes,
        )
        check_dir_manifest_limit(
          op,
          "max_new_bytes",
          identity.size,
          limits.max_new_bytes,
        )
        check_dir_manifest_limit(
          op,
          "max_output_bytes",
          identity.size,
          limits.max_output_bytes,
        )
      }
      Patched(old_identity~, new_identity~, patch_identity~, blob_name~, ..) => {
        check_dir_manifest_limit(
          op,
          "max_old_bytes",
          old_identity.size,
          limits.max_old_bytes,
        )
        check_dir_manifest_limit(
          op,
          "max_patch_bytes",
          patch_identity.size,
          limits.max_patch_bytes,
        )
        check_dir_manifest_limit(
          op,
          "max_new_bytes",
          new_identity.size,
          limits.max_new_bytes,
        )
        check_dir_manifest_limit(
          op,
          "max_output_bytes",
          new_identity.size,
          limits.max_output_bytes,
        )
        expected_blob_caps[blob_name] = limits.max_patch_bytes
      }
      Added(identity~, blob_name~, ..) => {
        check_dir_manifest_limit(
          op,
          "max_new_bytes",
          identity.size,
          limits.max_new_bytes,
        )
        check_dir_manifest_limit(
          op,
          "max_output_bytes",
          identity.size,
          limits.max_output_bytes,
        )
        expected_blob_caps[blob_name] = added_blob_cap
      }
      Deleted(old_identity~, ..) =>
        check_dir_manifest_limit(
          op,
          "max_old_bytes",
          old_identity.size,
          limits.max_old_bytes,
        )
    }
  }
  let old_tree_cap = dir_tree_byte_cap(limits.max_old_bytes)
  let blobs_total_cap = dir_tree_byte_cap(
    Int64::max(limits.max_patch_bytes, added_blob_cap),
  )
  check_dir_manifest_limit(
    op,
    "old_total_bytes",
    manifest.old_total_bytes,
    old_tree_cap,
  )
  check_dir_manifest_limit(
    op,
    "delta_payload_bytes",
    manifest.delta_payload_bytes,
    blobs_total_cap,
  )
  // Validate blobs/ filenames (and reject subdirectories inside blobs/) BEFORE reading any blob bytes.
  let blob_names = list_blobs_flat(op, bundle_dir)
  let present_blobs : Map[String, Unit] = Map([])
  for name in blob_names {
    if !expected_blob_caps.contains(name) {
      failure("\{op}: " + dir_delta_diagnostic(UnexpectedBlob(name)))
      abort("unreachable after process exit")
    }
    present_blobs[name] = ()
  }
  for entry in manifest.entries {
    match entry {
      Patched(blob_name~, ..) | Added(blob_name~, ..) =>
        if !present_blobs.contains(blob_name) {
          failure("\{op}: " + dir_delta_diagnostic(MissingBlob(blob_name)))
          abort("unreachable after process exit")
        }
      _ => ()
    }
  }
  // List OLD_DIR and verify old_file_count BEFORE reading OLD_DIR file contents into RAM.
  let old_rel_paths = list_dir_paths(op, "old", old_dir)
  if old_rel_paths.length() != manifest.old_file_count {
    failure(
      "\{op}: old directory file count mismatch: manifest expects \{manifest.old_file_count}, found \{old_rel_paths.length()}",
    )
    abort("unreachable after process exit")
  }
  let old_entries = read_dir_tree_paths(
    op,
    "old",
    old_dir,
    old_rel_paths,
    limits.max_old_bytes,
    old_tree_cap,
  )
  // Read each referenced blob using its exact action cap and anchored no-symlink IO.
  let blobs : Array[@manifest.DirBlob] = []
  let mut blobs_total_read = 0L
  for name in blob_names {
    let exact_cap = expected_blob_caps.get(name).unwrap()
    let remaining = blobs_total_cap - blobs_total_read
    let read_cap = Int64::min(exact_cap, remaining)
    let rel = "blobs/" + name
    let data = io_read_rel_nosymlink(
      path_bytes(bundle_dir),
      path_bytes(rel),
      read_cap.to_int(),
    )
    if io_failed() != 0 {
      let err = @utf8.decode_lossy(io_error()[:])
      if remaining < exact_cap && err.contains("byte limit") {
        failure(
          "\{op} read blob '\{name}' in '\{bundle_dir}': cumulative blob payload exceeds limit \{blobs_total_cap} bytes",
        )
      } else {
        failure(
          "\{op} read blob '\{name}' (limit=\{exact_cap} bytes) in '\{bundle_dir}': \{err}",
        )
      }
      abort("unreachable after process exit")
    }
    blobs_total_read += data.length().to_int64()
    blobs.push({ name, bytes: data, })
  }
  match @manifest.dir_apply(old_entries, manifest_bytes, blobs, limits) {
    Ok((restored, summary)) => (restored, summary, signer_key_id)
    Err(err) => {
      failure("\{op}: " + dir_delta_diagnostic(err))
      abort("unreachable after process exit")
    }
  }
}

///|
fn dir_verify_command(config : CliConfig) -> Unit {
  let op = config.operation
  let old_dir = config.files[0]
  let bundle_dir = config.files[1]
  let (_, summary, signer_key_id) = load_and_apply_dir_bundle(
    config, old_dir, bundle_dir,
  )
  if config.json {
    let fields = dir_summary_json_fields(op, summary, signer_key_id)
    fields["valid"] = @json.Json::boolean(true)
    fields["bundle_dir"] = @json.Json::string(bundle_dir)
    println(@json.Json::object(fields).stringify())
  } else {
    let title = if signer_key_id is Some(_) {
      "Directory verification succeeded: signature, manifest, inputs and restored tree match."
    } else {
      "Directory verification succeeded: manifest, inputs and restored tree match (not publisher authentication)."
    }
    print_dir_summary_text(title, summary, signer_key_id)
  }
}

///|
fn dir_patch_command(config : CliConfig) -> Unit {
  let op = config.operation
  let old_dir = config.files[0]
  let bundle_dir = config.files[1]
  let output_dir = config.files[2]
  let dir_inputs = [old_dir, bundle_dir]
  let inputs = [old_dir, bundle_dir]
  for pk in config.public_keys {
    inputs.push(pk)
  }
  if config.signature is Some(sig_path) {
    inputs.push(sig_path)
  }
  if !check_dir_output_against(dir_inputs, inputs, output_dir) {
    failure(
      "\{op} output '\{output_dir}': " + @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  let (restored, summary, signer_key_id) = load_and_apply_dir_bundle(
    config, old_dir, bundle_dir,
  )
  preflight_restored_paths(op, output_dir, restored)
  if io_mkdir_new(path_bytes(output_dir)) == 0 {
    failure(
      "\{op} create output directory '\{output_dir}': " +
      @utf8.decode_lossy(io_error()[:]),
    )
    return
  }
  let total_files = restored.length()
  let mut files_delivered = 0
  for entry in restored {
    if io_mkdir_parents(path_bytes(output_dir), path_bytes(entry.path)) == 0 {
      failure(
        "\{op} create parent directory for '\{entry.path}' (output directory '\{output_dir}' created; delivered \{files_delivered}/\{total_files} files): " +
        @utf8.decode_lossy(io_error()[:]) +
        "; no rollback attempted",
      )
      return
    }
    let out_file = join_child_path(output_dir, entry.path)
    if io_deliver(path_bytes(out_file), entry.bytes) == 0 {
      let detail = @utf8.decode_lossy(io_error()[:])
      let committed = delivered_output() != 0
      let count = if committed { files_delivered + 1 } else { files_delivered }
      let file_state = if committed {
        "delivered with an error"
      } else {
        "not delivered"
      }
      failure(
        "\{op} write '\{out_file}' (output directory '\{output_dir}' created; delivered \{count}/\{total_files} files; current file \{file_state}): \{detail}; no rollback attempted",
      )
      return
    }
    files_delivered = files_delivered + 1
  }
  if config.json {
    let fields = dir_summary_json_fields(op, summary, signer_key_id)
    fields["output_dir"] = @json.Json::string(output_dir)
    fields["restored_file_count"] = @json.Json::number(
      restored.length().to_double(),
    )
    println(@json.Json::object(fields).stringify())
  } else {
    print_dir_summary_text(
      "Directory patched successfully to '\{output_dir}'",
      summary,
      signer_key_id,
    )
  }
}
