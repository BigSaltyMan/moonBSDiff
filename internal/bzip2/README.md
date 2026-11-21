# Internal bzip2 encoder and decoder

Files `bits.mbt`, `bzip2.mbt`, `crc.mbt`, `decode.mbt`, `rand.mbt` originate from moonbitstack/moonzip 0.3.5, Copyright 2026 Leo Cheng, Apache-2.0. See LICENSE, source-lock.json and changes.patch. The root BSD-2-Clause license does not relicense those files. Modified 2026-11-06 for MoonBSDiff; source files carry modification notices.

The decoder subset retains the upstream compression format and transforms. The source lock gives original and adapted content hashes. The patch uses the original source as its old side and the local copied files as its new side; line endings are normalized to LF for the diff; apply it to the named original subset to reproduce the copied-file adaptations. New `bounded.mbt` implements the single-stream driver, budget and internal error bridge. New `moon.pkg` only imports core/debug. The upstream streaming Reader is outside this subset.

Changes: remove unused writer/sink and original one-shot driver; substitute a local error type; pass a Meter into read_block; reserve before RLE output; reject four-byte RLE runs missing their count; use subtraction for intermediate run bounds. The new driver verifies the combined CRC and computes its logical bit position for exact single-stream consumption. Huffman, MTF, inverse BWT, CRC and randomisation algorithms are preserved.

Package exports are implementation plumbing, not root-library API. They must not be treated as stable external APIs. `Budget.emitted` counts reserved/produced bytes across intervals and can also prove that failures stop before a disallowed RLE segment. `Decoded.blocks` counts actual parsed blocks, not byte-pattern matches. No public root debugging API was added.


Commit 26 (2026-11-15): bits.mbt adds bounded source refill; decode.mbt splits
read_rle_block (unchanged block transform) from the existing whole-output driver.
New original MoonBSDiff stream.mbt retains the bounded RLE-domain block and emits
final RLE incrementally, preserving CRC/end/budget state. It does not copy or
trust the dependency streaming Reader. The reproduction patch includes copied
file modifications; source-lock.json separately hashes the new driver. The
original Apache-2.0 notices and LICENSE are retained. See docs/file-apply.md.

## Encoder block boundaries

The internal Writer uses the Apache-2.0 encoder from the same pinned 0.3.5
release. The copied Writer and bit sink use separate files so they can share
CRC and marker code without replacing the strict decoder. The encoder patch
retains the existing BWT and MTF and removes the unused one-shot path. The
Writer checks available RLE space before transferring the run or charging it
to the current block CRC.

When the Huffman tree exceeds 20 bits, the encoder clamps its length histogram
and measures the Kraft excess in units of one 20-bit code. Each repair splits
a shorter code into two children and removes one 20-bit code, preserving the
symbol count and removing one unit of excess. Counting only the clamped leaves
could leave an oversubscribed table when the original tree was sufficiently
deep. The strict decoder uses the same checks as before.

Run `python scripts/check_compression.py --encoder-source` from a dependency
checkout to verify the original SHA-256 values and replay
`encoder-changes.patch`. The checker copies each mapped upstream file under
its local name in a temporary directory before applying the patch. It then
compares the reproduced source bytes against the adapted files.
