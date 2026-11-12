# Changelog

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
