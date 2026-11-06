# Application-stage acceptance (2026-11-06)

## Review and coverage map

Review baseline: dfcc2a63591eeef2b76d262ff6bc223b76d81a85, clean master. No implementation defect was found in control execution or the internal decoder. This step adds a default factory and evidence-driven integration/resource coverage; it does not change the apply algorithm, error structure or adapted bzip2 sources. No fabricated bug-regression directory was added.

| Behavior / limit | Existing evidence and assertions | Gap and resolution |
| --- | --- | --- |
| Legal upstream patches | 13 apply-upstream tests compare entire restored Bytes with original new.bin, snapshot inputs and retry | Reused unchanged fixtures; run with public application defaults |
| Negative z, consecutive seek, old positions outside either end | negative-z, outside-both, outside-high, minimum-cursor compare literal bytes | Already covered, including two zero-output seeks and Int64 minimum; no duplicate tests |
| Zero-output controls at scale | Existing minimum-cursor/instruction-cap tests | New native measurement executes 4096 zero-output triples before output, and 16384 ordinary triples |
| x/y invalid, output excess, cursor overflow/underflow | Existing negative-x/y, too-much-x/y, cursor-overflow-x/z, cursor-underflow assert kind/stage/field | Reused |
| Decoded alignment/consumption | Existing control-short, output-short, unused-control/diff/extra, diff-short/extra-short | Reused, including empty-target extra control rejection |
| Strict compressed consumption and CRC through apply | Existing crc and absolute-block-locations cover block CRC/header errors | Added 27 compact public-API variants across all three intervals, with/without output: truncation, combined CRC, trailing garbage, concatenated streams, and block CRC when nonempty |
| Actual old/patch/new/output limits | Existing old-limit/new-limit and format tests | Resource exact/one-short test now checks each input/header limit against a real valid patch; Header offsets None or 24 as documented |
| Shared decode budget | Existing shared-budget case | Valid patch uses exactly 50 bytes across control/diff/extra; 49 fails in Extra, then a fresh exact-budget call succeeds |
| Control data and count | Existing instruction-cap rejects oversized control expansion | Exact two-triple cap succeeds; one-triple cap rejects at Control/block_output_bytes before expansion/execution; Int64 max quota conversion is exercised with a small valid patch |
| Per-block decoded cap | Compact decoder unit contracts | New Diff/Extra public-API pairs accept two decoded bytes and reject three with cap two |
| Defaults | Previously absent | Public Limits::for_apply, exact values/validation asserted; all 13 upstream cases use it |

No independent control-byte field is needed: min(Int maximum, 24 * max_control_instructions), calculated with division before multiplication, already caps control expansion. Instruction count cannot reset between phases because one control stream and one finite execution loop are used. Shared decompression budget is created once per operation. Restore-size checks precede output allocation. Int64 cursor positions never determine allocation size or become Int indices before the old-buffer range check.

## Default policy and measurement basis

| Field | Application default | Basis |
| --- | --- | --- |
| max_old_bytes | 1048576 bytes | Measured 1 MiB diff-heavy and many-control old buffers |
| max_new_bytes / max_output_bytes | 1048576 bytes each | Measured 1 MiB diff, extra, repeat and control-heavy restores, with full byte assertions |
| max_patch_bytes | 65536 bytes | Largest measured patch 33325 bytes (seeded incompressible 32 KiB extra); 64 KiB is policy headroom, not a tested universal maximum |
| max_decompressed_bytes | 2097152 bytes | Largest measured total 1441792 bytes; 2 MiB provides headroom |
| max_control_instructions | 16384 triples | Actually executed 16384 ordinary triples; zero-output sample executes 4097 total |
| max_sort_work / max_match_work | 1 each | Unused by apply; positive fail-closed placeholders, unmeasured, not generation defaults |

These conservative defaults target small in-memory application. They are independent limits, not a claim that every 1 MiB input is accepted: an incompressible patch can exceed the patch cap. Explicit Limits remain supported. Default boundaries are supported by low-quota exact/one-short execution tests and asserted public field values. Measured scale is at most 1 MiB restored bytes, 33325 patch bytes, and 1441792 decoded bytes; other cap maxima have not been size-exhaustively accepted. Generation defaults and sorting/matching work definitions remain for later work.

## Resource evidence and reproduction

Saved record: testdata/apply/resource-measurements.json. Inputs, sizes and SHA-256 are reproducible from scripts/measure_apply.py. Eight inputs: diff and extra at 4096/1048576 bytes, 1 MiB repeated A, 16384 64-byte diff instructions, 4096 zero-output instructions followed by 4096 Z bytes, and random.Random(20261106).randbytes(32768) as extra. Python bz2 level 9 constructs legal independent patches. No upstream patch is regenerated.

Verified environment: Windows 11 build 26300, AMD64, MSVC 19.44.35229; moon 0.1.20261102 (ea07287), moonc 0.10.19+bee578715 and moonrun 0.1.20261102, all 2026-11-02 builds. Native release mode, default compiler flags. Initialize an MSVC developer shell, set MOON_HOME/PATH to the isolated toolchain, then run `python scripts/measure_apply.py` (Python plus psutil; tested psutil 7.2.2). The script generates a temporary ignored executable package, calls moon build --target native --release, runs the executable directly three times, verifies all eight outputs, and removes its temporary source package. Build/cache/executable outputs stay ignored. A 30-second process timeout prevents a hung measurement.

Final retained runs using Limits::for_apply: 0.124357, 0.107532, 0.111441 seconds for the entire eight-input process. Times include process startup, construction, apply and complete output assertions; they are not isolated apply latencies or throughput measurements. Sampled maximum resident memory: 17620992, 17719296, 17371136 bytes (about 16.6-16.9 MiB), with psutil RSS sampled every 1 ms. **Reliable peak memory: not measured.** The batch can retain arrays and GC state across cases; these RSS values are not per-call bounds. Initial candidate exploration and one metadata-encoding failure are not substituted for the final saved three-run record.

Structural estimate only: default logical payloads can include 1 MiB old + 64 KiB patch + 2 MiB decoded + 1 MiB output array + 1 MiB returned Bytes + up to 64 KiB copied compressed intervals, about 5.125 MiB. This excludes decoder temporary copies/workspaces, array capacity/headers, runtime, stack, allocator and GC. It is neither an estimate of complete peak memory nor a memory guarantee. Decoder workspace may be allocated even for small output budgets, as described in compression.md. CPU/wall-clock and whole-process memory are not bounded by Limits.

`python scripts/measure_apply.py --verify-report` checks saved input recipes/hashes and report structure offline; it does not reproduce historical timings. No resource measurement is run in CI or on JS/Wasm-GC.

## Actual stage validation

Final apply selection: `moon test apply_test.mbt apply_vectors_test.mbt apply_boundaries_test.mbt apply_resources_test.mbt --target TARGET --deny-warn`. One complete final run on each of native, JS and Wasm-GC passed 73/73. This comprises 13 unchanged independent upstream inputs, 26 existing independent manual cases, two existing additional tests, 27 new stream-mutation inputs, and five resource/default tests (with several paired assertions). Shared inputs across targets are not additional independent cases. Before final validation, an exploratory JS run of the 32 new tests also passed.

Native configuration/format regression: `moon test limits_test.mbt format_wbtest.mbt --target native --deny-warn`, 12/12 passed. moon info, moon fmt, moon fmt --check, native check --deny-warn, native build and git diff --check passed. Public interface adds only Limits::for_apply() -> Limits; apply's explicit signature is unchanged.

Python check_apply.py, check_apply_boundaries.py, measure_apply.py --verify-report, check_format_vectors.py and the single upstream offline integrity verification all passed. New fixtures are independently constructed with Python bz2; no MoonBSDiff diff is used for expectations. The internal bzip2 adaptation is untouched. Historical probes, large level-9 compression samples, C-oracle builds, upstream-patch regeneration and unrelated target matrices were skipped. No new peak-memory claim is made.

CI includes the new fixture/report checks and all four apply files on JS/Wasm-GC; its existing native full suite naturally includes the new tests. Remote CI has not run. Stage evidence establishes only upstream generation -> MoonBSDiff application, with no unexplained output differences. Diff, CLI and reverse interoperability remain unimplemented. BSDIFF40 does not authenticate the old file; callers must verify expected hashes externally.
