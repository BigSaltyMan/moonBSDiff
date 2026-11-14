# Rebuildable Wasm file update

The repository-owned v1/v2 MoonBit programs compute adjusted_size(40) as 41/42.
Both are real Wasm-GC executables, not renamed files. Use the pinned toolchain:
moon 0.1.20261102 (ea07287), moonc v0.10.19+bee578715 (2026-11-02), Node for the
memory example, Python 3 for orchestration, and a native C compiler for the CLI.
On Windows initialize an MSVC developer shell. From repository root:

```sh
python scripts/run_examples.py
```

This runs the in-memory example once, builds each module with
`moon build examples/wasm-update/v1 --target wasm-gc --release --strip --deny-warn`
(and v2), builds the official CLI with scripts/build_cli.py, then executes
`diff OLD NEW PATCH` and `patch OLD PATCH RESTORED`. A unique target-dir/output
directory is created under `_build/examples/run-<nonce>` every time. Existing
outputs and inputs are never overwritten. To reuse an already built CLI:

```sh
python scripts/run_examples.py --cli _build/bin/linux/moonbsdiff
# Windows: python scripts/run_examples.py --cli _build/bin/windows/moonbsdiff.exe
```

manifest.json fixes source identities and module hashes from an independent
Windows AMD64 compilation before any diff/apply execution. Normal runs never
refresh it from restored bytes. The original expected field retains the 0.1.0
Commit 14/15 evidence. Version-keyed expectations also cover 0.2.0: direct
compilation changed only byte 3888 of each Wasm custom name section, from
module @0.1.0 to @0.2.0; code/data bytes are identical. Unknown module versions
fail rather than selecting an arbitrary expectation. Each module is 3962 bytes, below CLI generation
limits. The script rejects a toolchain/source/module identity difference rather
than silently accepting platform drift. Other platforms must reproduce exactly;
final CI results establish which hosts did so. No cross-compiler reproducibility
beyond those exact settings is claimed. The target is Wasm-GC, not MVP Wasm.

Before applying, the old hash is checked. Afterward the restored file must equal
the directly compiled new module byte-for-byte AND match its fixed manifest hash.
Success ends with `EXAMPLES PASS` and an actual JSON report of source identities,
full tool versions, flags, sizes/hashes for old/new/patch/restored and byte_equal.
Any build, CLI, timeout, missing artifact or comparison error exits nonzero.
Raw binaries, patches and reports remain ignored under _build, not in source.

The script does not implement diff/apply in Python, use a C oracle, benchmark,
run a browser or inspect module internals. Patch size is reported even if larger;
a single sample says nothing about general compression. BSDIFF40 does not contain
old-file identity hashes. Linux CLI output follows the [primary/guarded delivery policy](../../docs/linux-delivery.md);
no power-loss durability guarantee is added. The memory example itself needs neither IO
nor this Python driver. Sources follow the repository BSD-2-Clause license.
