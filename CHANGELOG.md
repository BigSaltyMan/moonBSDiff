# Changelog

## Unreleased

- `manifest plan --max-steps COUNT` finds the cheapest route within a
  client's patch count limit.

- `verify-chain` checks a local patch chain through the final target hash.
  It keeps private intermediate files and hashes the last step in chunks
  without saving the final version.

- `patch-chain --progress text|json` emits step-aware progress to stderr,
  including verified intermediates and the final publication status.

- `patch-chain` checks a trusted chain of local patches and manifests,
  restores intermediate versions privately, and publishes the verified final file.

- `manifest plan` finds a directed update route with the smallest total
  declared patch size to a trusted target and returns the steps as JSON.

- `manifest select` matches the installed file by size and SHA-256 and returns
  JSON for the smallest applicable patch among trusted manifests for one target.

- `diff-many OLD (NEW PATCH MANIFEST)...` generates multiple patch bundles
  from one old index. It checks batch paths before writing and reports which
  files were delivered if a group fails.

- `manifest.BundleIndex` reuses one old version's suffix index and SHA-256
  across patch bundles while applying fresh generation budgets to every target.

- `manifest.diff` and `manifest.diff_with_options` return a standard BSDIFF40
  patch and its schema 1 manifest on native, JS and Wasm-GC. `diff --manifest`
  uses the same generation path.

- `BigSaltyMan/moonbsdiff/manifest` verifies a trusted schema 1 manifest and
  returns checked restored bytes on native, JS and Wasm-GC. Structured errors
  distinguish invalid manifests, limits, content mismatches and BSDIFF40 failures.

- The library exposes `inspect_deep(Bytes, Limits)` on native, JS and Wasm-GC.
  It returns read-only `DeepPatchInfo` or a structured `BsdiffError`.
  `inspect --deep` uses the same implementation and retains its success schema.

- `manifest create` checks an existing BSDIFF40 patch against an independently
  supplied target before writing a schema 1 manifest. It preserves the original
  patch and produces a manifest that `verify --stream` can consume.

- `inspect --deep` checks all BSDIFF40 streams and controls within explicit
  limits, and reports control counts and Diff, Extra and total expanded bytes
  in text or JSON. It needs only the patch.

- Native `verify --stream --manifest` checks recovery in bounded chunks and
  saves no restored output. Verified input copies, existing limits and cooperative
  cancellation apply. Success uses the existing verify output line.

- Native `patch --stream --manifest` verifies private copies of both inputs
  and hashes the temporary output in bounded chunks. Schema 1, resource limits,
  progress and cooperative cancellation apply. Delivery requires a matching
  output hash. Verified inputs use temporary disk space.

## 0.4.0 — 2026-11-16

Publication status and exact package/CLI identities are recorded separately in
[0.4.0 release notes](docs/release-0.4.0.md); this date identifies the prepared
release, and does not by itself prove registry or GitHub publication.

- File-only `patch --stream --progress text|json` reports real temporary-write
  bytes, final validation, commit preparation and completion on stderr. JSONL
  runtime diagnostics share schema 1; byte counts are decimal strings.
- Cooperative SIGINT (Linux) / Ctrl+C or Ctrl+Break (Windows) cancellation exits
  130 when confirmed before the native commit admission point, cleans owned
  temporary output and leaves subsequent calls independent. Late requests never
  trigger rollback; actual publication is reported, including failure after it.
- Native signal handlers only notify. Block computation may delay checkpoints;
  generator progress/cancellation, JS async execution and deadlines are absent.

- Explicit native `patch --stream` uses interval-bounded compressed reads,
  pausable final RLE emission and 4096-byte old/output chunks. Shared decoded
  budget and instruction limits persist across all blocks and streams.
- Block/combined CRC, real end markers and compressed/decoded complete
  consumption precede existing safe no-overwrite delivery; late errors never
  publish a partial successful output. Windows/Linux compact paths verified.
- Pure `inspect_header_prefix` shares envelope validation without whole patch
  buffering. Memory apply/default policies and dependencies stay unchanged.
- Stream/manifest combination is refused; concurrent inputs are not consistent
  snapshots. Format-bounded block workspaces remain; process peak memory,
  streaming generation and immediate/strict-time interruption are not promised.


### Included from the unissued 0.3.0 source work

- DiffOptions selects bzip2 compression level 1..9 (default 9), with ordinary and
  reusable-index diff_with_options APIs and diff-only CLI --compression-level.
  Invalid options fail before expensive work; default signatures/level remain.
- Control/difference/extra share one level and existing cumulative resource caps.
  New native evidence independently checks all nine streams, a parsed two-block
  level-1 extra stream and cached-upstream restoration; compact APIs run on
  native/JS/Wasm-GC and new CLI contracts on Windows/Linux. Tiny level 1/6/9
  timing samples have equal patch sizes and are not performance rankings.
- Manifest schema 1, dependencies, Limits factories and published CLI 0.2.0
  assets remain unchanged. No codec, parallel mode or Mooncakes release is added.

- Opaque DiffIndex::build / DiffIndex::diff reuse immutable old bytes and one
  suffix array across targets. Construction charges sorting once; every target
  rechecks its limits and receives a fresh matching/generation budget. Ordinary
  diff shares the same pipeline and retains its signature/default behavior.
- Five compact public API tests on native/JS/Wasm-GC cover multi-target reuse,
  deterministic independent results, exact quotas, failures/recovery and size
  caps. A small executable example shows two restored targets from one index.
- Historical larger-scale timings remain bound to their original Git sources;
  ordinary pushes check records, while large remeasurement requires explicit
  workflow_dispatch selection. No old measurements were refreshed for this API.

- Explicit measured 256 KiB and 1 MiB generation/application policies, complete
  machine-readable caps, deterministic replay, six native-release input pairs
  and two public CLI replays. Input/restoration hashes, cumulative work, raw
  blocks, patch sizes and core/invocation timing are recorded separately.
- GNU time invocation maximum RSS is distinguished from unmeasured API-only
  peak memory. Sparse, periodic and independent random cases passed; this is
  not acceptance of every size-compliant input or other targets at these sizes.
- Those scale policies use existing explicit Limits: no algorithm optimization,
  default factory or dependency change. Released CLI 0.2.0 assets and
  Mooncakes 0.1.0 identity are unchanged; Mooncakes 0.2.0 is still unpublished.

## 0.2.0 — GitHub CLI

- Windows AMD64 ZIP and Linux x86_64 tar.gz distributions include licenses,
  source/build identities, actual runtime dependencies, archive SHA-256 and
  unpacked-product verification. See [download/install](docs/cli-install.md);
  publication identity is the formal v0.2.0 Release and its successful source CI.
- This is the GitHub CLI distribution. Mooncakes 0.2.0 has not been published;
  published 0.1.0 package, tag and historical hashes remain unchanged.

- Linux retains anonymous/proc delivery as primary and adds a capability-selected
  guarded local-ext compatibility route using private objects and no-replace
  linkat. Unsafe permissions/filesystems fail closed; uncertain objects are retained
  with diagnostics, and post-link failure never rolls back the final path.
- Private forced tests and a real isolated no-proc, non-root ext4 roundtrip cover
  the addition. Windows, library API/defaults and dependencies are unchanged.

- Verify and optional patch --manifest share bounded strict schema-1 consumption,
  pre-apply input size/hash checks, header consistency, real in-memory apply and
  restored size/hash checks. Checked output is delivered only after success.
- Manifest reads are capped at 16 KiB and JSON depth 8; duplicate/unknown fields,
  invalid sizes/hashes and malformed content fail. Producer metadata is not trust.

- Diff can emit a separate schema-1 SHA-256 manifest for the actual old/new/patch
  buffers, with deterministic JSON and generated producer metadata. Patch bytes
  remain standard BSDIFF40; hashing uses pinned mooncrypt 0.4.7 (Apache-2.0).
- Both outputs use no-overwrite delivery with read-only alias preflight; patch
  delivery precedes manifest delivery. Partial failure reports the delivered
  patch and incomplete manifest without path-based rollback. No signature or
  publisher-authentication guarantee is added.

- Header-only CLI inspect with text/schema-versioned JSON, bounded patch reads,
  exact decimal-string byte fields and explicit unperformed checks. No decoder,
  restoration, deep mode or manifest verification runs.
- Minimal read-only inspect_header/PatchInfo API shares the existing structural
  parser while leaving application output policy and defaults unchanged.

- CLI diff/patch accept explicit resource caps with checked decimal and B/KiB/MiB
  byte parsing; work/control counts use positive decimals without units.
- --show-limits displays effective configuration without file IO; patch rejects
  unused sort/match options, and -- permits leading-hyphen paths.
- One validated configuration controls input reads and core calls. Defaults,
  library API, dependencies and no-overwrite delivery remain unchanged.
- These additions are included in CLI 0.2.0, not published Mooncakes 0.1.0.

## 0.1.0 — 2026-11-12

- In-memory diff/apply with structured errors, validated explicit Limits and
  separate for_diff/for_apply defaults.
- BSDIFF40 signed-magnitude integers, checked envelope boundaries, CRC-checked
  single bzip2 stream per block and exact compressed/decoded consumption.
- Internal binary suffix indexing and matching/segment selection, with cumulative
  logical generation work budgets and bounded encoder emissions.
- Windows/Linux native diff/patch/help/version CLI, bounded binary reads and
  no-overwrite file delivery; CLI apply patch cap is 128 KiB.
- Source-checkout memory/Wasm examples and fixed 31-input bidirectional reference
  CI, with explicit full/compact target scopes and source-bound result gates.
- Five-case native-release process benchmark with raw samples and honest memory
  limits. This is not a universal speed or memory guarantee.

Compatibility: bytes outside the old file contribute zero during apply, negative
seeks are allowed, and unused/trailing/concatenated compressed data is rejected.
BSDIFF40 has no old-file identity hash. Linux CLI output requires O_TMPFILE and
/proc. Complete buffers/copies and bzip2 workspaces can coexist; work counts are
not full CPU, wall-clock or process peak-memory budgets. See docs for exact scope.

Feature scope is frozen. No new formats, sync/network/GUI/tuning interfaces or
broader guarantees will be added for 0.1.0. The source audit, final-source CI, publication and independent registry
consumption are complete; [release evidence](docs/release-0.1.0.md) records exact
identities and remaining network/platform boundaries. No tag or binary download
asset was created. Compatibility fixes remain possible within this scope.

Release preparation: clean-source package audit, byte-checked external candidate
consumer and fresh-cache registry consumer entry point. Actual publication status is
recorded separately in the post-publication document; the uploaded preparation
source did not prefill release success.
