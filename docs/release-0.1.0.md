# MoonBSDiff 0.1.0 publication record — 2026-11-12

This is a **post-publication documentation record**. It is not part of the uploaded
0.1.0 source archive and must not be mistaken for that archive's source SHA.
The machine-readable record, including all 179 member hashes and dependency
manifest/license hashes, is [testdata/release/0.1.0.json](../testdata/release/0.1.0.json).

## Identity chain

- Task baseline: `0e67949d73493f0edade3fc6c50833b76dca02b4`.
- Preparation: `a25c4565014b28dbf81cda994c6f6fc62e5dc49f`.
- **Published source:** `156f461d7d9bba589b5f78020945a6d4e714b578`.
- [Successful source CI](https://github.com/BigSaltyMan/moonBSDiff/actions/runs/43178018685)
  uses that exact source/workflow SHA, attempt 1. All four jobs succeeded.
- [Live exact-version metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.1.0):
  BigSaltyMan/moonbsdiff 0.1.0, not deprecated, created
  `2026-11-12T07:51:06.024943+00:00`.
- [Public ZIP](https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.1.0.zip):
  **326294 bytes**, **179 files**, SHA-256
  `d16972902120bc971a118f927cd15612cd0aaf79cc0b48bf8561c9604a8fab63`.
  Registry checksum, Windows candidate and independently downloaded ZIP agree.
- Clean git-archive SHA-256:
  `5807f07d18e7f42eda0ba79f3ce10d4c07d4715e2ad086f0856834fee08950f5`.

Official `moon publish --dry-run` returned 202 Accepted; one actual publish from
the audited source returned 200 OK after BigSaltyMan authentication. Credentials
were temporarily made available only to the isolated SDK, outside the source;
the temporary credential file was removed. No tag, GitHub Release or binary asset
was created. The public module name remains lower-case moonbsdiff, repository name
moonBSDiff. Publication does not establish compatibility with future SDK versions.

## Audit and final-source validation

`release_audit.py` exported only the committed source, ran moon update, fmt --check,
info with byte-preservation checks and official package --list, then compared the
full ZIP member set/bytes to the export. Sources, tests, docs, examples, reproducible
scripts, fixed data and required BSD/Apache license materials are present. Hidden
Git/workflow files stay in Git; caches, personal config, downloaded upstream source
and reference executables are absent from the package. The resolved dependency
snapshot is moonzip 0.3.5, moonbase 0.4.2, mooncrypt 0.4.7, moondate 0.1.0 and
moonseed 0.1.0; .moon-lock is not a dependency version lock. Root public API and
algorithms are unchanged; only the module description changed for publication.

The first CI attempt exposed a release-check script assumption that MOON_HOME was
always explicitly set. The appended fix derives the default SDK from the selected
moon executable; it changes no core algorithm/gate. The published source is the
fixed SHA, not the failed preparation SHA. Audit rejection checks cover extra,
missing, duplicate and changed members. No check was weakened to obtain success.

Final published-source CI passed native 142 tests, native/JS/Wasm-GC check/build,
the existing full/compact selections, offline data checks, both CLI platforms and
the executable examples. Windows and Linux each ran 31 CLI file tests plus the
nine private IO contracts. The real reference job performed all 138 byte-exact
restorations over the unchanged 31 independent inputs (native 31 per direction,
JS and Wasm-GC 19 per direction), zero failures/skips. CI's clean candidate package
was consumed externally on all three targets. Its ZIP container hash differs from
the Windows-built ZIP; each was independently checked against the exact same
committed member bytes. No patch-byte identity across implementations is required.

## Actual registry consumption

A separate Windows/NTFS directory with a freshly copied pinned SDK, empty registry
and project caches, no credentials, no moon.work and no path dependency executed:

```sh
moon update
moon add BigSaltyMan/moonbsdiff@0.1.0
moon check --target js --deny-warn
moon build --target js
moon run . --target js
moon check --target wasm-gc --deny-warn
moon build --target wasm-gc
moon run . --target wasm-gc
moon check --target native --deny-warn
moon build --target native
moon run . --target native
```

Native was run in the installed MSVC developer environment after the JS/Wasm-GC
runs, reusing only this newly installed registry dependency. All commands returned
zero. Every target called the public diff/apply with the two default factories,
compared the full restored bytes to the predefined original target, and reported
old 21 bytes / new 22 bytes / patch 155 bytes / PASS. All 179 downloaded and
installed package members matched the published-source audit. This is actual
registry consumption, distinct from the pre-publication local workspace candidate.
SDK: moon 0.1.20261102 (ea07287 2026-11-02), moonc v0.10.19+bee578715
(2026-11-02), moonrun 0.1.20261102. The consumer source is the audited
cmd/example/main.mbt, not an internal API or alternative patch implementation.

The first Windows fresh bootstrap failed a TLS handshake; a second fresh run
succeeded. Two local Linux/WSL fresh bootstraps failed fetching the HTTPS Git index
with connection resets; a diagnostic HTTP/1.1 request also failed. Those are
**not** accepted Linux registry-consumer passes. Linux source/CLI/reference and
three-target candidate consumption remain separately proven by the successful
source CI. Certificate validation was never disabled; no failed run was counted.

To reproduce the stricter archive/installed-member checks, follow acceptance.md
using `release_audit.py --revision 156f461d7d9bba589b5f78020945a6d4e714b578`
and pass that audit to release_consumer.py without --candidate. System temporary
directories may be ephemeral; save emitted evidence before leaving that environment.

## Frozen scope and remaining boundaries

The nine acceptance areas in acceptance.md now have source, CI, public package and
independent-consumer evidence. The frozen feature scope is unchanged. Complete
buffer copies/workspaces can coexist; logical quotas are not hard wall-clock,
complete bzip2 CPU or process peak-memory budgets. BSDIFF40 does not authenticate
the old file. Strict stream/CRC/consumption and CLI no-overwrite behavior remain;
Linux output requires O_TMPFILE and /proc, with no power-loss durability promise.
No new measurements, formats, sync/network features, GUI, tuning options or wider
platform/scale guarantee are added. Compatibility defects and necessary fixes can
still be addressed; there is no claim that all malicious inputs have been proved
safe. The known local Linux registry-network gap is retained above.
