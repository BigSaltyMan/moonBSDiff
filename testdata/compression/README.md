# Compression fixtures

Twelve small offline Python-bz2 streams, levels 1 and 9; inputs and regeneration are in `scripts/check_compression.py`, hashes in manifest.json. `python scripts/check_compression.py` verifies files and generated literals without regenerating them. Use `--generate` explicitly to rebuild; Python/libbz2 output changes require review, not automatic acceptance. Data is generated from project-owned literals and periodic byte sequences; no third-party user data is included.

The same compact compressed bytes are embedded in `compression_vectors_wbtest.mbt` because this toolchain has no file-embedding attribute. The expanded inputs are reconstructed in MoonBit. The largest compressed file is 1885 bytes; large raw inputs are not embedded as giant hex arrays. The fixture-source checker detects stale or modified copies.

Four compact contract tests run across native/JS/Wasm-GC. One native-only-by-command large test reconstructs boundary inputs and checks real decoder block counts. One separately filtered native test records fixed-dependency gaps. See `docs/compression.md` and results.json for actual execution and cost boundaries. Default native CI runs all tests; JS/Wasm-GC CI selects only compression-compact*.
