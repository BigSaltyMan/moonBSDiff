# Apply test inputs

`manifest.json` associates embedded test inputs with IDs, sizes, SHA-256, expected error category/stage/field, and reviewable manual control triples. The first 13 cases reuse unchanged old/new/patch bytes from `testdata/upstream/manifest.json`. The remaining 26 are constructed by `scripts/check_apply.py` with independent Python integers and bz2 level 9. Expected output bytes are literal original data, not MoonBSDiff-generated results. Error cases have no expected successful output.

`python scripts/check_apply.py` verifies every embedded literal against the source fixtures or independent constructor, plus the manual control inventory. `python scripts/check_apply.py --generate` followed by `moon fmt` reproduces the embedding. No C oracle is invoked. The generated tests are `apply_vectors_test.mbt`; two further tests in `apply_test.mbt` check compressed block absolute error locations and the README memory example.

2026-11-06 execution: native, JS and Wasm-GC each passed all 41 apply tests (13 upstream cases, 26 manual cases, two additional tests). Native configuration/format regression passed 12 tests; native compact compression contracts passed four tests with four emitted level-9 streams independently verified by Python. Each generated apply case snapshots old/patch inputs and checks a fresh successful call afterward. The 13 upstream outputs are compared as complete Bytes against original new bytes.

Skipped by design: large compression boundaries, dependency-gap reproduction, historical probes, rebuilding the C oracle, regenerating upstream patches, and full cross-target regressions. This is upstream-generated patch -> MoonBSDiff application evidence only. Remote CI has not run.
