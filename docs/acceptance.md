# 0.1.0 source/package acceptance

Post-publication update: [actual release evidence](release-0.1.0.md) now records
successful source CI, upload and Windows three-target registry consumption.
The preparation procedure below is retained with its original evidence boundary.

The release source is frozen only after its commit has passed the matching CI.
This preparation document does not assert a future upload or registry consumer.
The post-publication record is a separate documentation commit that must identify
its relationship to the uploaded source; it does not replace that source SHA.

## Gates and reproduction

Use moon 0.1.20261102 (ea07287 2026-11-02), moonc
v0.10.19+bee578715 (2026-11-02). Native needs a C compiler; consumers on JS need
Node. Keep the SDK selected through MOON_HOME and PATH; do not upgrade globally.

```sh
python scripts/release_audit.py --revision HEAD
```

This exports tracked bytes with git archive into a fresh system temporary folder,
initializes dependency metadata, checks formatting, regenerates and compares all
tracked interfaces/source bytes, and invokes official moon package --list. Every
ZIP member must exactly match the clean export: no extra/missing/duplicate names,
unsafe paths or CRC differences. Dotfiles/workflows are intentionally absent from
the published archive under the current default packager policy; they remain in
Git. Sources, tests, fixed offline data, examples, docs, scripts, C IO source and
all required licenses stay in the archive. No cache, credentials, executable or
reference source download is included. The output reports source SHA, archive
and package SHA-256, member hashes, exact resolved dependency manifests/licenses,
commands and SDK identity. Temporary absolute paths are local evidence only.

Use the emitted AUDIT_JSON and its PACKAGE_ZIP with:

```sh
python scripts/release_consumer.py --candidate PACKAGE_ZIP --audit AUDIT_JSON --targets native js wasm-gc
```

This clones only the selected SDK runtime/compiler/core into a new temporary home
without credentials or registry caches, unpacks the audited ZIP outside the repo,
and consumes it through an explicit local workspace. It checks/builds/runs a
public diff/apply binary-byte example and compares predefined expected bytes.
This is **candidate validation**, not registry consumption. It never substitutes
working-tree library files. Missing output, child failure or byte mismatch fails.

After matching-source CI succeeds and BigSaltyMan authentication is verified,
run official moon publish once from the audited clean source, keeping private
credentials outside the source tree. On uncertain network results inspect live
registry state before considering another attempt. No tag/Release is necessary.

After publication, in the same fixed SDK environment:

```sh
python scripts/release_consumer.py --audit AUDIT_JSON --targets native js wasm-gc
```

Without --candidate it creates a fresh external project, SDK registry and package
cache, runs moon update and moon add BigSaltyMan/moonbsdiff@0.1.0, and uses no
workspace/path override. It independently downloads the public ZIP, compares its
full member set and bytes to the audited source, verifies every installed member,
and executes the public API example on the requested targets. It records both
ZIP identities: ZIP metadata may differ but member bytes must match exactly.
The actual outcome belongs in the post-publication record, not here in advance.

## Final validation and nine acceptance areas

The matching-source CI executes native full tests, JS/Wasm-GC declared full/compact
selections, nonzero/failure gates, offline fixed-data checks, the two native CLI
platform tasks, and the two executable examples. The separate locked reference
job runs the unchanged 31-input bidirectional matrix (native 31 each direction,
JS/Wasm-GC 19 each); no results are inferred from self-roundtrips. The new package
step exports the same SHA and performs the external candidate consumer on all
three targets. CI does not rerun timing benchmarks. Actual run URL/SHA and results
must be checked before upload.

| Acceptance area | Evidence location |
| --- | --- |
| MoonBit implementation and compiler baseline | root sources, pkg.generated.mbti, CI version logs |
| Public project and history | BigSaltyMan/moonBSDiff, source SHA and CI |
| Complete core API | diff/apply, explicit Limits and default factories |
| Reproducible documentation | README, format/apply/generation/CLI docs |
| check/build/test CI | .github/workflows/ci.yml, actual matching run |
| Executable examples | cmd/example, examples/wasm-update, CI |
| Core correctness and independent interoperability | compatibility report, strict reference job |
| Actual Mooncakes release and independent consumer | post-publication record; pending at preparation |
| OSI license and attribution | LICENSE, docs/upstream.md, internal/bzip2/LICENSE, tools/oracle license texts |

BSD-2-Clause applies to original code and the retained BSDiff-derived portions;
moonzip 0.3.5 and the attributed decoder subset retain Apache-2.0. Dependency
resolution is recorded at audit time; the .moon-lock mutex is not a version lock.
Core/API/limits and dependency requirements are not expanded for release.

## Guarantee boundary

This is complete-buffer binary patching with logical resource budgets, not a
streaming, hard wall-clock or whole-process peak-memory guarantee. BSDIFF40 does
not authenticate the old file. Strict single-stream CRC, compressed and decoded
consumption rules remain unchanged. Native CLI output needs the documented
Windows/Linux facilities; Linux requires O_TMPFILE and /proc and no power-loss
durability is promised. No formats, GUI, directory/network synchronization,
tuning options, broader platforms or resource guarantees are added. Benchmarks
remain the small historical process measurements in benchmarks.md.
