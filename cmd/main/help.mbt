///|
fn print_usage(operation : String, flags? : String) -> Unit {
  let (default_flags, paths) = match operation {
    "diff" => ("[OPTIONS]", "OLD_FILE NEW_FILE PATCH_FILE")
    "diff-many" => ("[OPTIONS]", "OLD (NEW PATCH MANIFEST)...")
    "patch" => ("[OPTIONS]", "OLD_FILE PATCH_FILE OUTPUT_FILE")
    "patch-chain" =>
      (
        "--target-manifest FILE [--progress text|json] [LIMITS]", "OLD OUTPUT (PATCH MANIFEST)...",
      )
    "verify-chain" =>
      (
        "--target-manifest FILE [--progress text|json] [LIMITS]", "OLD (PATCH MANIFEST)...",
      )
    "verify" =>
      (
        "[--stream] --manifest MANIFEST_FILE [--public-key KEY_FILE --signature SIG_FILE] [LIMITS]",
        "OLD_FILE PATCH_FILE",
      )
    "manifest" => ("[LIMITS]", "OLD_FILE NEW_FILE PATCH_FILE MANIFEST_FILE")
    "manifest select" =>
      ("[LIMITS]", "OLD_FILE MANIFEST_FILE [MANIFEST_FILE...]")
    "manifest plan" =>
      (
        "--target-manifest FILE [--max-steps COUNT] [--max-download-bytes VALUE] [--allow-full] [LIMITS]",
        "OLD_FILE [MANIFEST_FILE...]",
      )
    "manifest plan-local" =>
      (
        "--target-manifest FILE [--local-patch FILE ...] [--max-steps COUNT] [LIMITS]",
        "OLD_FILE [MANIFEST_FILE...]",
      )
    "manifest keygen" => ("[--json]", "PRIVATE_KEY_FILE PUBLIC_KEY_FILE")
    "manifest sign" =>
      ("[--json] --private-key KEY_FILE", "MANIFEST_FILE SIGNATURE_FILE")
    "manifest verify-sig" =>
      ("[--json] --public-key KEY_FILE --signature SIG_FILE", "MANIFEST_FILE")
    "install-full" =>
      (
        "--target-manifest FILE [--public-key KEY_FILE --signature SIG_FILE] [--max-new-bytes VALUE] [--max-output-bytes VALUE]",
        "DOWNLOADED_FILE OUTPUT_FILE",
      )
    "inspect" => ("[--deep] [--json] [--max-patch-bytes VALUE]", "PATCH_FILE")
    _ => abort("missing usage for CLI command")
  }
  let name = if operation == "manifest" { "manifest create" } else { operation }
  let options = match flags {
    Some(value) => value
    None => default_flags
  }
  let option_prefix = if options == "" { "" } else { options + " " }
  println("moonbsdiff \{name} \{option_prefix}\{paths}")
}

///|
fn print_manifest_help() -> Unit {
  println(
    "moonbsdiff manifest <create|select|plan|plan-local|keygen|sign|verify-sig> --help",
  )
  println(
    "  create      Write a manifest after checking a patch against OLD_FILE and NEW_FILE.",
  )
  println(
    "  select      Choose the smallest patch for the installed file and one target.",
  )
  println("  plan        Choose a download route to the target.")
  println("  plan-local  Find an offline route using local patch files.")
  println("  keygen      Generate a detached Ed25519 signing keypair.")
  println("  sign        Sign a Schema 1 manifest with an Ed25519 private key.")
  println("  verify-sig  Verify a detached Ed25519 manifest signature.")
}

///|
fn print_limit_help(operation : String) -> Unit {
  let lookup = operation == "manifest select" ||
    operation == "manifest plan" ||
    operation == "manifest plan-local"
  if operation == "inspect" {
    println("  --max-patch-bytes VALUE     Maximum patch size.")
    println("  With --deep only:")
    println("    --max-output-bytes VALUE    Maximum declared restored size.")
  } else {
    if operation != "install-full" {
      println("  --max-old-bytes VALUE       Maximum old file size.")
      println("  --max-patch-bytes VALUE     Maximum patch size.")
    }
    println("  --max-new-bytes VALUE       Maximum target size.")
    println(
      "  --max-output-bytes VALUE    Independent target buffer or output cap.",
    )
  }
  if !lookup && operation != "install-full" {
    let expanded = if operation == "diff" || operation == "diff-many" {
      "Raw control, diff and extra bytes."
    } else {
      "Total decoded bytes across streams."
    }
    let indent = if operation == "inspect" { "    " } else { "  " }
    println(indent + "--max-expanded-bytes VALUE  " + expanded)
    println(
      indent + "--max-controls COUNT        Maximum control instructions.",
    )
  }
  if operation == "diff" || operation == "diff-many" {
    println("  --max-sort-work COUNT       Sorting work limit.")
    println("  --max-match-work COUNT      Matching and generation work limit.")
  }
  println(
    "Byte limits take positive decimals with optional B, KiB or MiB. Counts take positive decimals without units.",
  )
}

///|
fn print_command_help(operation : String) -> Unit {
  print_usage(operation)
  match operation {
    "diff" | "diff-many" => {
      println("  --compression-level VALUE  bzip2 level 1..9 (default 9).")
      if operation == "diff" {
        println(
          "  --manifest MANIFEST_FILE   Write the SHA-256 JSON manifest after the patch.",
        )
        println(
          "  --show-limits              Print effective limits and exit. Omit paths and --manifest.",
        )
      } else {
        println(
          "Each group names one input and two outputs. Earlier files remain if a later delivery fails.",
        )
        println(
          "Example: moonbsdiff diff-many --compression-level 6 stable.bin beta.bin beta.patch beta.json rc.bin rc.patch rc.json",
        )
      }
    }
    "patch" => {
      println(
        "  --manifest MANIFEST_FILE   Verify input and restored bytes against a trusted manifest.",
      )
      println(
        "  --public-key KEY_FILE      Verify detached manifest signature (requires --manifest and --signature).",
      )
      println(
        "  --signature SIG_FILE       Detached Ed25519 signature file for --manifest (requires --public-key).",
      )
      println(
        "  --stream                  Apply with bounded file I/O. Ctrl+C requests cancellation.",
      )
      println(
        "  --progress text|json      Report progress to stderr. Requires --stream.",
      )
      println(
        "  --show-limits             Print effective limits and exit. Omit paths, --manifest and --stream.",
      )
    }
    "patch-chain" | "verify-chain" => {
      if operation == "patch-chain" {
        println("Verify each patch in order and write only the final OUTPUT.")
      } else {
        println(
          "Verify each patch in order and hash the final result without writing an output file.",
        )
      }
      println(
        "  --target-manifest FILE    Required. Supplies the expected final file identity.",
      )
      println(
        "  --progress text|json     Report progress to stderr. Confirmed cancellation exits 130.",
      )
    }
    "verify" => {
      println("Verify a patch without writing restored output.")
      println(
        "  --manifest MANIFEST_FILE  Required. Supplies the expected file identities.",
      )
      println(
        "  --public-key KEY_FILE     Require detached signature authentication (with --signature).",
      )
      println(
        "  --signature SIG_FILE      Detached Ed25519 signature file (with --public-key).",
      )
      println(
        "  --stream                 Hash restored chunks without buffering the full result.",
      )
    }
    "inspect" => {
      println("Read the patch header by default.")
      println(
        "  --deep                   Check streams, CRC, controls and consumption without restoring.",
      )
      println("  --json                   Write inspection results as JSON.")
    }
    "install-full" => {
      println(
        "Verify the downloaded file by size and SHA-256 before writing OUTPUT_FILE without replacement.",
      )
      println(
        "  --target-manifest FILE   Required. Supplies the expected file identity.",
      )
      println(
        "  --public-key KEY_FILE    Verify detached target manifest signature (with --signature).",
      )
      println(
        "  --signature SIG_FILE     Detached Ed25519 signature file (with --public-key).",
      )
    }
    "manifest" =>
      println(
        "Apply PATCH_FILE to OLD_FILE in memory. Write MANIFEST_FILE only if the result equals NEW_FILE.",
      )
    "manifest select" =>
      println(
        "Choose the smallest matching patch for one target. Equal sizes favor the first. Output is JSON.",
      )
    "manifest plan" => {
      println(
        "Plan the fewest patch bytes, then the fewest steps, and write JSON.",
      )
      println(
        "  --target-manifest FILE        Required. Supplies the expected target file identity.",
      )
      println(
        "  --max-steps COUNT             Limit the number of patch applications.",
      )
      println(
        "  --max-download-bytes VALUE    Limit total download bytes. Zero is allowed.",
      )
      println(
        "  --allow-full                  Consider downloading the complete target.",
      )
    }
    "manifest plan-local" => {
      println(
        "Match local patches by size and SHA-256, then write the offline route in JSON.",
      )
      println(
        "  --target-manifest FILE   Required. Supplies the expected target file identity.",
      )
      println(
        "  --local-patch FILE       Supply a local patch file. Repeat for each available patch.",
      )
      println(
        "  --max-steps COUNT        Limit the number of patch applications.",
      )
      println("Put candidate MANIFEST_FILE paths after OLD_FILE.")
    }
    "manifest keygen" => {
      println(
        "Generate a detached Ed25519 signing keypair using the OS CSPRNG without overwriting existing files.",
      )
      println("  --json  Write key metadata (never the private seed) as JSON.")
    }
    "manifest sign" => {
      println(
        "Sign an existing Schema 1 manifest file with an Ed25519 private key.",
      )
      println(
        "  --private-key KEY_FILE  Required. Ed25519 private key JSON file.",
      )
      println("  --json                  Write signature metadata as JSON.")
    }
    "manifest verify-sig" => {
      println(
        "Verify a detached Ed25519 signature against a Schema 1 manifest and pinned public key.",
      )
      println(
        "  --public-key KEY_FILE  Required. Pinned Ed25519 public key JSON file.",
      )
      println(
        "  --signature SIG_FILE   Required. Detached manifest signature JSON file.",
      )
      println("  --json                 Write verification result as JSON.")
    }
    _ => abort("missing help for CLI command")
  }
  if operation != "manifest keygen" &&
    operation != "manifest sign" &&
    operation != "manifest verify-sig" {
    print_limit_help(operation)
  }
  println("Place options before paths. Use -- before paths starting with '-'.")
}

///|
fn help_flag(value : String) -> Bool {
  value == "--help" || value == "-h"
}

///|
fn print_requested_help(args : Array[String]) -> Bool {
  if args.length() == 2 && help_flag(args[1]) {
    print_help()
    return true
  }
  if args.length() == 3 && args[1] == "manifest" && help_flag(args[2]) {
    print_manifest_help()
    return true
  }
  if parse_command(args) is Ok((operation, options_start)) &&
    args.length() == options_start + 1 &&
    help_flag(args[options_start]) {
    print_command_help(operation)
    return true
  }
  false
}

///|
fn print_help() -> Unit {
  print_usage("diff", flags="")
  print_usage("diff-many")
  println(
    "Example: moonbsdiff diff-many --compression-level 6 stable.bin beta.bin beta.patch beta.json rc.bin rc.patch rc.json",
  )
  println(
    "Each diff-many group names one input and two outputs. Earlier files remain if a later delivery fails.",
  )
  print_usage("patch", flags="")
  print_usage("patch-chain")
  println(
    "Apply verified local patches in order and deliver only the final file. Confirmed cancellation exits 130.",
  )
  print_usage("verify-chain")
  println(
    "Verify local patches in order. The final step hashes restored bytes without saving a file.",
  )
  print_usage(
    "patch",
    flags="--stream [--manifest MANIFEST_FILE [--public-key KEY_FILE --signature SIG_FILE]] [--progress text|json]",
  )
  println(
    "Progress/diagnostics go to stderr. Ctrl+C (Windows also Ctrl+Break) requests cooperative cancellation, exit 130 before commit; no rollback after commit begins.",
  )
  println(
    "--stream: native bounded file apply; --manifest verifies private input copies and the restored bytes.",
  )
  println("moonbsdiff --help | -h | --version")
  println("For command help, use moonbsdiff COMMAND --help or -h.")
  println("For manifest subcommands, use moonbsdiff manifest --help.")
  print_usage("verify")
  print_usage("manifest")
  println(
    "manifest create applies the existing patch in memory and writes a manifest only if the result matches NEW_FILE byte for byte. The patch is unchanged.",
  )
  print_usage("manifest select")
  println(
    "Select the smallest matching patch from manifests for one target. Equal sizes favor the first. Prints JSON and reads no patches.",
  )
  println(
    "Manifest select limits: --max-old-bytes, --max-new-bytes, --max-output-bytes, --max-patch-bytes.",
  )
  print_usage("manifest plan")
  println(
    "Plan the fewest patch bytes, then the fewest steps. Prints JSON and reads no patches.",
  )
  println(
    "Plan limits: --max-patch-bytes caps each patch, --max-steps caps patch applications (positive count), and --max-download-bytes caps the whole update (zero allowed).",
  )
  println(
    "Use --allow-full to compare patch bytes with the complete target and print the download strategy.",
  )
  print_usage("manifest plan-local")
  println(
    "Match local patches by size and SHA-256, then print the offline route in application order.",
  )
  print_usage("install-full")
  println(
    "Verify the downloaded file against the target size and SHA-256 before delivering it without replacement.",
  )
  print_usage("manifest keygen")
  print_usage("manifest sign")
  print_usage("manifest verify-sig")
  println(
    "Detached Ed25519 manifest signing and verification (4096-byte key/signature caps; mode 0600 on POSIX, owner DACL on Windows for private keys).",
  )
  print_usage(
    "patch",
    flags="--manifest MANIFEST_FILE [--public-key KEY_FILE --signature SIG_FILE] [LIMITS]",
  )
  println(
    "Manifest input: at most 16384 bytes, schema 1, no duplicate/unknown keys. Verify uses memory by default; --stream hashes restored chunks. Neither saves restored output.",
  )

  println(
    "--manifest MANIFEST_FILE: diff writes; patch/verify read and validate the SHA-256 JSON manifest.",
  )
  println(
    "Patch then manifest are delivered without replacement; two-file delivery is not atomic.",
  )
  print_usage("inspect")
  println(
    "Deep inspect also accepts --max-output-bytes, --max-expanded-bytes and --max-controls.",
  )
  println(
    "inspect reads the header by default. --deep checks streams, CRC, controls and consumption without restoring a file.",
  )
  println("With options: moonbsdiff diff|patch [OPTIONS] FILE FILE FILE")
  println(
    "Diff and diff-many: --compression-level VALUE (positive decimal 1..9; default 9; no units).",
  )
  println(
    "Display only: moonbsdiff diff|patch [OPTIONS] --show-limits (no files)",
  )
  println(
    "Options precede all paths; -- ends options and allows leading '-' paths.",
  )
  println(
    "Byte options (diff/diff-many/patch/verify/patch-chain/verify-chain/manifest create): --max-old-bytes, --max-new-bytes, --max-output-bytes, --max-patch-bytes, --max-expanded-bytes VALUE",
  )
  println(
    "Bytes: ASCII decimal with optional case-sensitive B, KiB or MiB. Positive except for the download budget; no spaces or signs.",
  )
  println(
    "Count (diff/diff-many/patch/verify/patch-chain/verify-chain/manifest create): --max-controls VALUE. Diff and diff-many: --max-sort-work, --max-match-work VALUE.",
  )
  println(
    "Counts/work: positive decimal integers, no units. Each option occurs at most once; use separate values, not '='.",
  )
  println(
    "Expanded bytes: raw control/diff/extra for diff; cumulative decoded bytes for patch.",
  )
  println(
    "New and output caps constrain the target independently; patch bytes have a separate cap.",
  )
  println(
    "Match work includes generation; increasing one cap does not increase any other.",
  )

  println(
    "Binary files only. Existing outputs (including links) are never replaced.",
  )
  println(
    "diff: old/new/output 65536 bytes, patch 131072, raw 262144, 4096 controls; sort/match 8388608 each.",
  )
  println(
    "patch: old/output 1048576 bytes, patch 131072, decoded 2097152, 16384 controls.",
  )
  println(
    "Linux output prefers O_TMPFILE+/proc; macOS and guarded local-ext compatibility use 0700 private staging in a protected parent. No durability guarantee.",
  )
  println(
    "Exit codes: 0 success, 2 arguments, 1 operation failure. BSDIFF40 does not identify the old file.",
  )
}
