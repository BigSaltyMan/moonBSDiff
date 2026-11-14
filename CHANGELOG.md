# Changelog

## 0.3.0 — Unreleased

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
