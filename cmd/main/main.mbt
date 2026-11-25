///|
#borrow(path)
extern "C" fn io_read(path : Bytes, cap : Int32) -> Bytes = "mbsd_read"

///|
#borrow(a, b, out)
extern "C" fn io_check(a : Bytes, b : Bytes, out : Bytes) -> Int32 = "mbsd_output_check"

///|
#borrow(path)
extern "C" fn io_input_check(path : Bytes) -> Int32 = "mbsd_input_check"

///|
#borrow(input, out)
extern "C" fn io_input_alias_check(input : Bytes, out : Bytes) -> Int32 = "mbsd_input_alias_check"

///|
#borrow(a, b)
extern "C" fn io_pair_check(a : Bytes, b : Bytes) -> Int32 = "mbsd_pair_check"

///|
#borrow(path, data)
extern "C" fn io_deliver(path : Bytes, data : Bytes) -> Int32 = "mbsd_deliver"

///|
extern "C" fn io_error() -> Bytes = "mbsd_io_error"

///|
extern "C" fn io_failed() -> Int32 = "mbsd_io_failed"

///|
#borrow(text)
extern "C" fn stderr(text : Bytes) -> Unit = "mbsd_stderr"

///|
fn path_bytes(path : String) -> Bytes {
  @utf8.encode(path[:]) + b"\x00"
}

///|
fn check_output_against(inputs : Array[String], output : String) -> Bool {
  let out_bytes = path_bytes(output)
  for inp in inputs {
    if io_input_alias_check(path_bytes(inp), out_bytes) == 0 {
      return false
    }
  }
  io_check(b"\x00", b"\x00", out_bytes) != 0
}

///|
fn failure(text : String) -> Unit {
  stderr(@utf8.encode(("moonbsdiff: " + text + "\n")[:]))
  @env.exit(1)
}

///|
fn read_input(operation : String, path : String, cap : Int64) -> Bytes {
  let value = io_read(path_bytes(path), cap.to_int())
  if io_failed() != 0 {
    failure(operation + " '" + path + "': " + @utf8.decode_lossy(io_error()[:]))
  }
  value
}

///|
extern "C" fn native_arg_count() -> Int32 = "mbsd_arg_count"

///|
extern "C" fn native_arg(index : Int32) -> String = "mbsd_arg"

///|
fn cli_args() -> Array[String] {
  let count = native_arg_count()
  if count == -1 {
    @env.args()
  } else if count == -3 {
    stderr(
      @utf8.encode(
        ("moonbsdiff: command-line arguments: " +
        @utf8.decode_lossy(io_error()[:]) +
        "\n")[:],
      ),
    )
    @env.exit(2)
    []
  } else if count < 0 {
    failure("command-line arguments: " + @utf8.decode_lossy(io_error()[:]))
    []
  } else {
    Array::makei(count, i => native_arg(i))
  }
}

///|
// ASCII-only decimals; check both decimal and unit arithmetic before use.
fn parse_limit(
  text : String,
  bytes : Bool,
  allow_zero~ : Bool,
) -> Result[Int64, String] {
  let raw = @utf8.encode(text[:])
  let mut end = raw.length()
  let mut multiplier = 1L
  if bytes &&
    end >= 3 &&
    raw[end - 2].to_int() == 105 &&
    raw[end - 1].to_int() == 66 {
    if raw[end - 3].to_int() == 75 {
      multiplier = 1024L
      end = end - 3
    } else if raw[end - 3].to_int() == 77 {
      multiplier = 1048576L
      end = end - 3
    }
  } else if bytes && end >= 1 && raw[end - 1].to_int() == 66 {
    end = end - 1
  }
  if end == 0 {
    return Err(
      if allow_zero {
        "expected a nonnegative decimal value"
      } else {
        "expected a positive decimal value"
      },
    )
  }
  let mut value = 0L
  for i = 0; i < end; i = i + 1 {
    let digit = raw[i].to_int() - 48
    if digit < 0 || digit > 9 {
      return Err(
        "expected ASCII digits" +
        (if bytes { " with optional B, KiB or MiB" } else { " without units" }),
      )
    }
    if value > (9223372036854775807L - digit.to_int64()) / 10L {
      return Err("decimal value overflows Int64")
    }
    value = value * 10L + digit.to_int64()
  }
  if value == 0L && !allow_zero {
    return Err("value must be positive; zero is not unlimited")
  }
  if value > 9223372036854775807L / multiplier {
    return Err("unit conversion overflows Int64")
  }
  Ok(value * multiplier)
}

///|
struct CliConfig {
  operation : String
  limits : @moonbsdiff.Limits
  options : @moonbsdiff.DiffOptions
  progress : String
  stream : Bool
  show : Bool
  json : Bool
  deep : Bool
  analyze : Bool
  manifest : String?
  target_manifest : String?
  private_key : String?
  public_keys : Array[String]
  signature : String?
  target_signature : String?
  step_signatures : Array[String]
  local_patches : Array[String]
  min_catalog_version : Int64?
  current_version : Int64?
  target_version : Int64?
  max_steps : Int64?
  max_download_bytes : Int64?
  allow_full : Bool
  files : Array[String]
}

///|
fn leading_dash(text : String) -> Bool {
  text.length() > 0 && text.code_unit_at(0) == 45
}

///|
fn is_known_option(option : String) -> Bool {
  match option {
    "--help"
    | "-h"
    | "--version"
    | "--progress"
    | "--stream"
    | "--compression-level"
    | "--manifest"
    | "--target-manifest"
    | "--private-key"
    | "--public-key"
    | "--signature"
    | "--target-signature"
    | "--step-signature"
    | "--min-catalog-version"
    | "--current-version"
    | "--target-version"
    | "--max-steps"
    | "--local-patch"
    | "--max-download-bytes"
    | "--allow-full"
    | "--deep"
    | "--analyze"
    | "--json"
    | "--show-limits"
    | "--max-old-bytes"
    | "--max-new-bytes"
    | "--max-output-bytes"
    | "--max-patch-bytes"
    | "--max-expanded-bytes"
    | "--max-decompressed-bytes"
    | "--max-controls"
    | "--max-control-instructions"
    | "--max-sort-work"
    | "--max-match-work" => true
    _ => false
  }
}

///|
fn parse_command(args : Array[String]) -> Result[(String, Int32), String] {
  if args.length() < 2 ||
    (
      args[1] != "diff" &&
      args[1] != "diff-many" &&
      args[1] != "patch" &&
      !is_chain(args[1]) &&
      args[1] != "inspect" &&
      args[1] != "verify" &&
      args[1] != "install-full" &&
      args[1] != "dir-diff" &&
      args[1] != "dir-verify" &&
      args[1] != "dir-patch" &&
      args[1] != "manifest"
    ) {
    return Err(
      "expected diff, diff-many, patch, patch-chain, inspect, verify, verify-chain, install-full, dir-diff, dir-verify, dir-patch, or manifest create/select/plan/plan-local/keygen/sign/verify-sig/catalog; use --help",
    )
  }
  let (operation, options_start) = if args[1] == "manifest" {
    if args.length() < 3 {
      return Err(
        "manifest requires create, select, plan, plan-local, keygen, sign, verify-sig or catalog; use --help",
      )
    }
    match args[2] {
      "create" => ("manifest", 3)
      "select" => ("manifest select", 3)
      "plan" => ("manifest plan", 3)
      "plan-local" => ("manifest plan-local", 3)
      "keygen" => ("manifest keygen", 3)
      "sign" => ("manifest sign", 3)
      "verify-sig" => ("manifest verify-sig", 3)
      "catalog" => {
        if args.length() < 4 {
          return Err(
            "manifest catalog requires sign, verify or plan; use --help",
          )
        }
        match args[3] {
          "sign" => ("manifest catalog sign", 4)
          "verify" => ("manifest catalog verify", 4)
          "plan" => ("manifest catalog plan", 4)
          _ =>
            return Err(
              "manifest catalog requires sign, verify or plan; use --help",
            )
        }
      }
      _ =>
        return Err(
          "manifest requires create, select, plan, plan-local, keygen, sign, verify-sig or catalog; use --help",
        )
    }
  } else {
    (args[1], 2)
  }
  Ok((operation, options_start))
}

///|
let max_public_keys : Int32 = 64

///|
fn parse_cli(args : Array[String]) -> Result[CliConfig, String] {
  let (operation, options_start) = match parse_command(args) {
    Ok(command) => command
    Err(message) => return Err(message)
  }
  let chain = is_chain(operation)
  let generation = operation == "diff" || operation == "diff-many"
  let diff_limits = generation || operation == "dir-diff"
  let dir_op = operation == "dir-diff" ||
    operation == "dir-verify" ||
    operation == "dir-patch"
  let local_plan = operation == "manifest plan-local"
  let plan = operation == "manifest plan" || local_plan
  let manifest_lookup = operation == "manifest select" || plan
  let mut i = options_start
  let mut limits = if diff_limits {
    @moonbsdiff.Limits::for_diff()
  } else {
    @moonbsdiff.Limits::for_apply()
  }
  let mut options = @moonbsdiff.DiffOptions::default()
  let seen : Array[String] = []
  let mut progress = "none"
  let mut stream = false
  let mut show = false
  let mut json = false
  let mut deep = false
  let mut analyze = false
  let mut manifest : String? = None
  let mut target_manifest : String? = None
  let mut private_key : String? = None
  let public_keys : Array[String] = []
  let mut signature : String? = None
  let mut target_signature : String? = None
  let step_signatures : Array[String] = []
  let local_patches : Array[String] = []
  let mut min_catalog_version : Int64? = None
  let mut current_version : Int64? = None
  let mut target_version : Int64? = None
  let mut max_steps : Int64? = None
  let mut max_download_bytes : Int64? = None
  let mut allow_full = false
  let mut escaped = false
  while i < args.length() {
    let option = args[i]
    if option == "--" {
      escaped = true
      i = i + 1
      break
    }
    if !leading_dash(option) {
      break
    }
    if !is_known_option(option) {
      return Err("unknown option: " + option)
    }
    if operation == "inspect" &&
      option != "--json" &&
      option != "--deep" &&
      option != "--analyze" &&
      option != "--max-patch-bytes" &&
      option != "--max-output-bytes" &&
      option != "--max-expanded-bytes" &&
      option != "--max-decompressed-bytes" &&
      option != "--max-controls" &&
      option != "--max-control-instructions" {
      return Err(option + " is not applicable to inspect")
    }
    if operation == "install-full" &&
      option != "--target-manifest" &&
      option != "--public-key" &&
      option != "--signature" &&
      option != "--max-new-bytes" &&
      option != "--max-output-bytes" {
      return Err(option + " is not applicable to install-full")
    }
    if operation == "manifest keygen" && option != "--json" {
      return Err(option + " is not applicable to manifest keygen")
    }
    if (operation == "manifest sign" || operation == "manifest catalog sign") &&
      option != "--json" &&
      option != "--private-key" {
      return Err(option + " is not applicable to " + operation)
    }
    if operation == "manifest verify-sig" &&
      option != "--json" &&
      option != "--public-key" &&
      option != "--signature" {
      return Err(option + " is not applicable to manifest verify-sig")
    }
    if operation == "manifest catalog verify" &&
      option != "--json" &&
      option != "--public-key" &&
      option != "--signature" &&
      option != "--min-catalog-version" {
      return Err(option + " is not applicable to manifest catalog verify")
    }
    if operation == "manifest catalog plan" &&
      option != "--json" &&
      option != "--public-key" &&
      option != "--signature" &&
      option != "--current-version" &&
      option != "--target-version" &&
      option != "--min-catalog-version" &&
      option != "--max-steps" &&
      option != "--max-download-bytes" &&
      option != "--allow-full" &&
      option != "--max-old-bytes" &&
      option != "--max-new-bytes" &&
      option != "--max-output-bytes" &&
      option != "--max-patch-bytes" {
      return Err(option + " is not applicable to manifest catalog plan")
    }
    if manifest_lookup &&
      option != "--max-old-bytes" &&
      option != "--max-new-bytes" &&
      option != "--max-output-bytes" &&
      option != "--max-patch-bytes" &&
      !(operation == "manifest plan" &&
      (
        option == "--target-manifest" ||
        option == "--max-steps" ||
        option == "--max-download-bytes" ||
        option == "--allow-full"
      )) &&
      !(local_plan &&
      (
        option == "--target-manifest" ||
        option == "--max-steps" ||
        option == "--local-patch"
      )) {
      return Err(option + " is not applicable to " + operation)
    }
    let bytes = match option {
      "--progress" => {
        if operation != "patch" && !chain {
          return Err(
            "--progress is only applicable to patch --stream, patch-chain or verify-chain",
          )
        }
        false
      }
      "--stream" => {
        if operation != "patch" && operation != "verify" {
          return Err("--stream is only applicable to patch or verify")
        }
        false
      }
      "--compression-level" => {
        if !generation {
          return Err(option + " is only applicable to diff and diff-many")
        }
        false
      }
      "--manifest" => {
        if operation == "manifest" {
          return Err("manifest create takes MANIFEST_FILE as a file argument")
        }
        if operation == "diff-many" {
          return Err("diff-many takes a MANIFEST file argument per group")
        }
        if chain {
          return Err(operation + " takes a MANIFEST file argument per step")
        }
        if dir_op {
          return Err(option + " is not applicable to " + operation)
        }
        false
      }
      "--private-key" => {
        if operation != "manifest sign" &&
          operation != "manifest catalog sign" &&
          operation != "dir-diff" {
          return Err(
            "--private-key is only applicable to manifest sign, manifest catalog sign or dir-diff",
          )
        }
        false
      }
      "--public-key" => {
        if operation != "manifest verify-sig" &&
          operation != "manifest catalog verify" &&
          operation != "manifest catalog plan" &&
          operation != "verify" &&
          operation != "patch" &&
          operation != "install-full" &&
          operation != "dir-verify" &&
          operation != "dir-patch" &&
          !chain {
          return Err(
            option + " is only applicable to signature-verifying commands",
          )
        }
        false
      }
      "--signature" => {
        if operation != "manifest verify-sig" &&
          operation != "manifest catalog verify" &&
          operation != "manifest catalog plan" &&
          operation != "verify" &&
          operation != "patch" &&
          operation != "install-full" &&
          operation != "dir-verify" &&
          operation != "dir-patch" {
          return Err(
            option +
            " is only applicable to manifest verify-sig, manifest catalog verify/plan, verify, patch, install-full, dir-verify or dir-patch",
          )
        }
        false
      }
      "--target-signature" | "--step-signature" => {
        if !chain {
          return Err(
            option + " is only applicable to patch-chain or verify-chain",
          )
        }
        false
      }
      "--min-catalog-version" => {
        if operation != "manifest catalog verify" &&
          operation != "manifest catalog plan" {
          return Err(
            option + " is only applicable to manifest catalog verify or plan",
          )
        }
        false
      }
      "--current-version" | "--target-version" => {
        if operation != "manifest catalog plan" {
          return Err(option + " is only applicable to manifest catalog plan")
        }
        false
      }
      "--max-steps" => {
        if !plan && operation != "manifest catalog plan" {
          return Err(
            option +
            " is only applicable to manifest plan, plan-local or catalog plan",
          )
        }
        false
      }
      "--local-patch" => {
        if !local_plan {
          return Err(option + " is only applicable to manifest plan-local")
        }
        false
      }
      "--max-download-bytes" | "--allow-full" => {
        if operation != "manifest plan" && operation != "manifest catalog plan" {
          return Err(
            option + " is only applicable to manifest plan or catalog plan",
          )
        }
        option == "--max-download-bytes"
      }
      "--target-manifest" => {
        if !plan && operation != "install-full" && !chain {
          return Err(
            option +
            " is only applicable to manifest plan, plan-local, install-full, patch-chain or verify-chain",
          )
        }
        false
      }
      "--deep" | "--analyze" => {
        if operation != "inspect" {
          return Err(option + " is only applicable to inspect")
        }
        false
      }
      "--json" => {
        if operation != "inspect" &&
          operation != "manifest keygen" &&
          operation != "manifest sign" &&
          operation != "manifest verify-sig" &&
          operation != "manifest catalog sign" &&
          operation != "manifest catalog verify" &&
          operation != "manifest catalog plan" &&
          !dir_op {
          return Err(
            "--json is only applicable to inspect, manifest keygen/sign/verify-sig, manifest catalog, or dir-* commands",
          )
        }
        false
      }
      "--show-limits" => {
        if operation == "verify" ||
          operation == "manifest" ||
          operation == "diff-many" ||
          dir_op ||
          chain {
          let command = if operation == "manifest" {
            "manifest create"
          } else {
            operation
          }
          return Err(option + " is not applicable to " + command)
        }
        false
      }
      "--max-old-bytes"
      | "--max-new-bytes"
      | "--max-output-bytes"
      | "--max-patch-bytes"
      | "--max-expanded-bytes"
      | "--max-decompressed-bytes" => true
      "--max-controls" | "--max-control-instructions" => false
      "--max-sort-work" | "--max-match-work" => {
        if !diff_limits {
          return Err(option + " is not applicable to " + operation)
        }
        false
      }
      "--help" | "-h" | "--version" =>
        return Err(option + " is not applicable to " + operation)
      _ => return Err("unknown option: " + option)
    }
    let seen_key = match option {
      "--max-decompressed-bytes" => "--max-expanded-bytes"
      "--max-control-instructions" => "--max-controls"
      _ => option
    }
    if option != "--local-patch" &&
      option != "--public-key" &&
      option != "--step-signature" {
      if seen.contains(seen_key) {
        return Err("duplicate option: " + option)
      }
      seen.push(seen_key)
    }
    if option == "--stream" {
      stream = true
      i += 1
      continue
    }
    if option == "--deep" {
      deep = true
      i += 1
      continue
    }
    if option == "--analyze" {
      analyze = true
      i += 1
      continue
    }
    if option == "--json" {
      json = true
      i = i + 1
      continue
    }
    if option == "--allow-full" {
      allow_full = true
      i += 1
      continue
    }
    if option == "--show-limits" {
      show = true
      i = i + 1
      continue
    }
    if i + 1 >= args.length() {
      return Err("missing value for " + option)
    }
    if option == "--progress" {
      let value = args[i + 1]
      if value != "text" && value != "json" {
        return Err("--progress requires text or json")
      }
      progress = value
      i += 2
      continue
    }
    if option == "--manifest" ||
      option == "--target-manifest" ||
      option == "--local-patch" ||
      option == "--private-key" ||
      option == "--public-key" ||
      option == "--signature" ||
      option == "--target-signature" ||
      option == "--step-signature" {
      let path = args[i + 1]
      if path.length() == 0 || leading_dash(path) {
        return Err(
          option +
          " requires a nonempty path value; use ./ for a leading '-' name",
        )
      }
      match option {
        "--manifest" => manifest = Some(path)
        "--local-patch" => local_patches.push(path)
        "--target-manifest" => target_manifest = Some(path)
        "--private-key" => private_key = Some(path)
        "--public-key" => {
          if public_keys.length() >= max_public_keys {
            return Err(
              "--public-key may be specified at most \{max_public_keys} times",
            )
          }
          public_keys.push(path)
        }
        "--target-signature" => target_signature = Some(path)
        "--step-signature" => step_signatures.push(path)
        _ => signature = Some(path)
      }
      i = i + 2
      continue
    }
    let is_download_budget = option == "--max-download-bytes"
    let value = match
      parse_limit(args[i + 1], bytes, allow_zero=is_download_budget) {
      Ok(v) => v
      Err(e) => return Err(option + ": " + e)
    }
    if is_download_budget {
      max_download_bytes = Some(value)
      i += 2
      continue
    }
    if option == "--max-steps" {
      max_steps = Some(value)
      i += 2
      continue
    }
    if option == "--min-catalog-version" {
      min_catalog_version = Some(value)
      i += 2
      continue
    }
    if option == "--current-version" {
      current_version = Some(value)
      i += 2
      continue
    }
    if option == "--target-version" {
      target_version = Some(value)
      i += 2
      continue
    }
    if option == "--compression-level" {
      if value < 1L || value > 9L {
        return Err("--compression-level must be in 1..9")
      }
      options = { compression_level: value.to_int(), }
      i = i + 2
      continue
    }
    limits = match option {
      "--max-old-bytes" => { ..limits, max_old_bytes: value, }
      "--max-new-bytes" => { ..limits, max_new_bytes: value, }
      "--max-output-bytes" => { ..limits, max_output_bytes: value, }
      "--max-patch-bytes" => { ..limits, max_patch_bytes: value, }
      "--max-expanded-bytes" | "--max-decompressed-bytes" =>
        { ..limits, max_decompressed_bytes: value, }
      "--max-controls" | "--max-control-instructions" =>
        { ..limits, max_control_instructions: value, }
      "--max-sort-work" => { ..limits, max_sort_work: value, }
      "--max-match-work" => { ..limits, max_match_work: value, }
      _ => limits
    }
    i = i + 2
  }
  let files : Array[String] = []
  while i < args.length() {
    if !escaped && leading_dash(args[i]) {
      return Err(
        "options must precede file arguments; use -- before paths starting with '-'",
      )
    }
    files.push(args[i])
    i = i + 1
  }
  if show && files.length() != 0 {
    return Err(
      "--show-limits accepts no file arguments and never executes an operation",
    )
  }
  if show && manifest is Some(_) {
    return Err("--manifest cannot be combined with --show-limits")
  }
  if show && (!public_keys.is_empty() || signature is Some(_)) {
    return Err(
      "--public-key and --signature cannot be combined with --show-limits",
    )
  }
  if progress != "none" && !stream && !chain {
    return Err("--progress requires patch --stream")
  }
  if stream && show {
    return Err("--stream cannot be combined with --show-limits")
  }
  if operation == "verify" && manifest is None {
    return Err("verify requires --manifest MANIFEST_FILE")
  }
  if (operation == "manifest sign" || operation == "manifest catalog sign") &&
    private_key is None {
    return Err("\{operation} requires --private-key KEY_FILE")
  }
  if (
      operation == "manifest verify-sig" ||
      operation == "manifest catalog verify" ||
      operation == "manifest catalog plan"
    ) &&
    (public_keys.is_empty() || signature is None) {
    return Err(
      "\{operation} requires --public-key KEY_FILE and --signature SIG_FILE",
    )
  }
  if operation == "manifest catalog plan" &&
    (current_version is None || target_version is None) {
    return Err(
      "manifest catalog plan requires --current-version V and --target-version V",
    )
  }
  if (
      operation == "verify" ||
      operation == "install-full" ||
      operation == "dir-verify" ||
      operation == "dir-patch"
    ) &&
    !public_keys.is_empty() != (signature is Some(_)) {
    return Err("--public-key and --signature must be provided together")
  }
  if operation == "patch" && (!public_keys.is_empty() || signature is Some(_)) {
    if public_keys.is_empty() || signature is None {
      return Err("--public-key and --signature must be provided together")
    }
    if manifest is None {
      return Err("--public-key and --signature require --manifest on patch")
    }
  }
  if operation == "inspect" && deep && analyze {
    return Err("--deep and --analyze cannot be combined")
  }
  if operation == "inspect" && !deep && !analyze {
    for
      option in ["--max-output-bytes", "--max-expanded-bytes", "--max-controls"] {
      if seen.contains(option) {
        return Err(option + " requires inspect --deep or --analyze")
      }
    }
  }
  let expected = if operation == "inspect" ||
    operation == "manifest verify-sig" ||
    operation == "manifest catalog verify" {
    1
  } else if operation == "verify" ||
    operation == "dir-verify" ||
    operation == "manifest keygen" ||
    operation == "manifest sign" ||
    operation == "manifest catalog sign" ||
    operation == "manifest catalog plan" {
    2
  } else if operation == "manifest" {
    4
  } else {
    3
  }
  if operation == "diff-many" {
    if files.length() < 4 || (files.length() - 1) % 3 != 0 {
      return Err(
        "diff-many requires OLD followed by complete NEW PATCH MANIFEST groups; use --help",
      )
    }
  } else if operation == "manifest select" {
    if files.length() < 2 {
      return Err(
        "manifest select requires OLD_FILE and at least one MANIFEST_FILE; use --help",
      )
    }
  } else if plan {
    if files.length() == 0 || target_manifest is None {
      return Err(
        "\{operation} requires --target-manifest FILE and OLD_FILE; use --help",
      )
    }
  } else if operation == "install-full" {
    if files.length() != 2 || target_manifest is None {
      return Err(
        "install-full requires --target-manifest FILE, DOWNLOADED_FILE and OUTPUT_FILE; use --help",
      )
    }
  } else if chain {
    let first_pair = chain_first_pair(operation)
    if target_manifest is None ||
      files.length() < first_pair + 2 ||
      (files.length() - first_pair) % 2 != 0 {
      let inputs = if first_pair == 2 { "OLD OUTPUT" } else { "OLD" }
      return Err(
        "\{operation} requires --target-manifest FILE, \{inputs} and complete PATCH MANIFEST pairs; use --help",
      )
    }
    let has_chain_sig = !public_keys.is_empty() ||
      target_signature is Some(_) ||
      !step_signatures.is_empty()
    if has_chain_sig {
      if public_keys.is_empty() {
        return Err(
          "\{operation} requires at least one --public-key with --target-signature/--step-signature",
        )
      }
      if target_signature is None {
        return Err(
          "\{operation} requires --target-signature when --public-key is supplied",
        )
      }
      let step_count = (files.length() - first_pair) / 2
      if step_signatures.length() != step_count {
        return Err(
          "\{operation} requires one --step-signature per PATCH MANIFEST step (expected \{step_count}, got \{step_signatures.length()})",
        )
      }
    }
  } else if !show && files.length() != expected {
    return Err("expected exactly \{expected} file arguments; use --help")
  }
  match limits.validate() {
    Ok(_) => ()
    Err(e) => return Err(@debug.to_string(e))
  }
  match options.validate() {
    Ok(_) => ()
    Err(e) => return Err(@debug.to_string(e))
  }
  Ok({
    operation,
    limits,
    options,
    progress,
    stream,
    show,
    json,
    deep,
    analyze,
    manifest,
    target_manifest,
    private_key,
    public_keys,
    signature,
    target_signature,
    step_signatures,
    local_patches,
    min_catalog_version,
    current_version,
    target_version,
    max_steps,
    max_download_bytes,
    allow_full,
    files,
  })
}

///|
fn show_limits(config : CliConfig) -> Unit {
  let l = config.limits
  println("operation: \{config.operation}")
  println("max_old_bytes: \{l.max_old_bytes} bytes")
  println("max_new_bytes: \{l.max_new_bytes} bytes")
  println(
    "max_output_bytes: \{l.max_output_bytes} bytes (target buffer; patch has separate cap)",
  )
  println("max_patch_bytes: \{l.max_patch_bytes} bytes")
  let meaning = if config.operation == "diff" {
    "raw control + diff + extra"
  } else {
    "cumulative decoded control + diff + extra"
  }
  println(
    "max_decompressed_bytes: \{l.max_decompressed_bytes} bytes (\{meaning})",
  )
  println(
    "max_control_instructions: \{l.max_control_instructions} instructions",
  )
  if config.operation == "diff" {
    println(
      "compression_level: \{config.options.compression_level} (generation option; bzip2)",
    )
    println("max_sort_work: \{l.max_sort_work} work units")
    println(
      "max_match_work: \{l.max_match_work} work units (matching + generation)",
    )
  } else {
    println("max_sort_work: unused by patch (no generation budget)")
    println("max_match_work: unused by patch (no generation budget)")
  }
}

///|
fn main {
  let args = cli_args()
  if print_requested_help(args) {
    return
  }
  if args.length() == 2 && args[1] == "--version" {
    println("moonbsdiff \{@manifest_support.PRODUCER_VERSION}")
    @env.exit(0)
  }
  let config = match parse_cli(args) {
    Ok(v) => v
    Err(e) => {
      stderr(@utf8.encode(("moonbsdiff: " + e + "\n")[:]))
      @env.exit(2)
      return
    }
  }
  if config.show {
    show_limits(config)
    @env.exit(0)
  }
  if config.operation == "inspect" {
    inspect_command(config)
    return
  }
  if config.operation == "verify" {
    verify_command(config)
    return
  }
  if config.operation == "manifest" {
    manifest_create_command(config)
    return
  }
  if config.operation == "manifest select" {
    manifest_select_command(config)
    return
  }
  if config.operation == "install-full" {
    install_full_command(config)
    return
  }
  if config.operation == "manifest plan-local" {
    manifest_plan_local_command(config)
    return
  }
  if config.operation == "manifest plan" {
    manifest_plan_command(config)
    return
  }
  if config.operation == "manifest keygen" {
    manifest_keygen_command(config)
    return
  }
  if config.operation == "manifest sign" {
    manifest_sign_command(config)
    return
  }
  if config.operation == "manifest verify-sig" {
    manifest_verify_sig_command(config)
    return
  }
  if config.operation == "manifest catalog sign" {
    manifest_catalog_sign_command(config)
    return
  }
  if config.operation == "manifest catalog verify" {
    manifest_catalog_verify_command(config)
    return
  }
  if config.operation == "manifest catalog plan" {
    manifest_catalog_plan_command(config)
    return
  }
  if config.operation == "dir-diff" {
    dir_diff_command(config)
    return
  }
  if config.operation == "dir-verify" {
    dir_verify_command(config)
    return
  }
  if config.operation == "dir-patch" {
    dir_patch_command(config)
    return
  }
  if is_chain(config.operation) {
    stream_command(config)
    return
  }
  if config.operation == "diff-many" {
    diff_many_command(config)
    return
  }
  let operation = config.operation
  let limits = config.limits
  let first = config.files[0]
  let second = config.files[1]
  let output = config.files[2]
  if config.stream {
    stream_command(config)
    return
  }
  let inputs = [first, second]
  if operation == "patch" {
    if config.manifest is Some(manifest_path) {
      inputs.push(manifest_path)
    }
    for pub_path in config.public_keys {
      inputs.push(pub_path)
    }
    if config.signature is Some(sig_path) {
      inputs.push(sig_path)
    }
  }
  if !check_output_against(inputs, output) {
    failure(
      operation +
      " output '" +
      output +
      "' (inputs '" +
      first +
      "', '" +
      second +
      "'): " +
      @utf8.decode_lossy(io_error()[:]),
    )
  }
  if operation == "patch" && config.manifest is Some(_) {
    let restored = verified_restore(config)
    if io_deliver(path_bytes(output), restored) == 0 {
      failure(
        "patch verified write/deliver '" +
        output +
        "': " +
        @utf8.decode_lossy(io_error()[:]),
      )
    }
    return
  }
  if operation == "diff" && config.manifest is Some(manifest_path) {
    if io_check(
        path_bytes(first),
        path_bytes(second),
        path_bytes(manifest_path),
      ) ==
      0 {
      failure(
        "manifest output '" +
        manifest_path +
        "': " +
        @utf8.decode_lossy(io_error()[:]),
      )
    }
    if io_pair_check(path_bytes(output), path_bytes(manifest_path)) == 0 {
      failure(
        "patch/manifest output conflict: " + @utf8.decode_lossy(io_error()[:]),
      )
    }
  }
  // All native caps were validated as positive Int-indexable bytes before any IO.
  let old = read_input(
    operation + " read old (max_old_bytes=\{limits.max_old_bytes} bytes)",
    first,
    limits.max_old_bytes,
  )
  let other = read_input(
    operation +
    " read " +
    (if operation == "diff" {
      "new (max_new_bytes=\{limits.max_new_bytes} bytes)"
    } else {
      "patch (max_patch_bytes=\{limits.max_patch_bytes} bytes)"
    }),
    second,
    if operation == "diff" {
      limits.max_new_bytes
    } else {
      limits.max_patch_bytes
    },
  )
  let result = if operation == "diff" && config.manifest is Some(_) {
    @manifest.diff_with_options(old, other, limits, config.options).map(bundle => {
      (bundle.patch, Some(bundle.manifest))
    })
  } else if operation == "diff" {
    @moonbsdiff.diff_with_options(old, other, limits, config.options).map(patch => {
      (patch, None)
    })
  } else {
    @moonbsdiff.apply(old, other, limits).map(restored => (restored, None))
  }
  let (value, manifest_data) = match result {
    Ok(v) => v
    Err(e) => {
      failure(
        operation +
        " inputs '" +
        first +
        "', '" +
        second +
        "' -> '" +
        output +
        "': " +
        @debug.to_string(e),
      )
      return
    }
  }
  if io_deliver(path_bytes(output), value) == 0 {
    failure(
      operation +
      " write/deliver '" +
      output +
      "': " +
      @utf8.decode_lossy(io_error()[:]),
    )
  }
  if config.manifest is Some(manifest_path) && manifest_data is Some(data) {
    if io_deliver(path_bytes(manifest_path), data) == 0 {
      failure(
        "patch delivered to '" +
        output +
        "'; manifest not completed at '" +
        manifest_path +
        "': " +
        @utf8.decode_lossy(io_error()[:]) +
        "; no rollback attempted",
      )
    }
  }
}
