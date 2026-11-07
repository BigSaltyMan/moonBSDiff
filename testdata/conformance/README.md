# Fixed interoperability inventory

`manifest.json` is the authoritative two-way matrix: 13 unchanged Commit 3 input
pairs plus 18 LCG32-v1 edit recipes. Fixed original inputs/patches remain in
`../upstream/`; random bytes are regenerated from explicit seeds and edits.
All expected outputs are original new bytes, independent of MoonBSDiff.

`python scripts/run_conformance.py` verifies recipes, input hashes and target
lists offline without reference tools. `--run` executes the actual matrix in a
new ignored directory; `--case ID --targets TARGET` provides a replay. Inventory
differences fail instead of updating expectations. See
[commands, protocol, coverage and evidence limits](../../docs/compatibility.md).

`last-run.json` is the small summary copied from the completed full run; it
identifies library sources, inputs via manifest hash, toolchain, C tools, every
generated patch, restored contents and raw results. It does not mean the matrix
has been rerun for a later source state. Raw outputs/logs remain under ignored
`_build/conformance/`, not in the repository.

New recipes and infrastructure use the project's BSD-2-Clause license. Historical
fixture provenance and BSDiff's Colin Percival notice remain in
`../upstream/README.md` and `docs/upstream.md`; reference executables are not shipped.
