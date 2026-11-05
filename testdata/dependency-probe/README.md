# bzip2 dependency probe

The preserved `main.mbt` and `vectors.json` are from the 2026-11-04 independent probe; `prior-report.json` is its historical report, not a current test result. Python 3.14.6 generated six cases: empty; UTF-8 bytes `4d6f6f6e42697420e5a29ee9878fe8a1a5e4b8810d0a`; bytes 0..255; bytes `61626331323300` repeated 4096 times; `random.Random(20261104).randbytes(4096)`; and `bytes(range(256))*430`. Python bz2 compressed them at level 1. The preserved program decodes each Python stream, compares the bytes, then compresses at level 1; `verify.py` checks each resulting stream with Python bz2.

Run from repository root with moon 0.10.19 and Python on PATH: `python testdata/dependency-probe/verify.py native` (also accepts `js` or `wasm-gc`). On Windows native, run from an MSVC developer environment. It writes only under ignored `_build/`.

2026-11-05 local recheck: `python testdata/dependency-probe/verify.py` with each of `native`, `js`, and `wasm-gc` passed all six cases in both directions using moonc 0.10.19 and level 1.

2026-11-04 report: six cases passed on native, JS and Wasm-GC; wasm was checked only. This is dependency feasibility evidence, not BSDiff functionality. Level 9, strict stream end, input consumption boundaries, and decompression budget enforcement are not established by this probe and remain for Commit 4.
