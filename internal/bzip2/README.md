# Fixed internal bzip2 decoder

Files `bits.mbt`, `bzip2.mbt`, `crc.mbt`, `decode.mbt`, `rand.mbt` originate from moonbitstack/moonzip 0.3.5, Copyright 2026 Leo Cheng, Apache-2.0. See LICENSE, source-lock.json and changes.patch. The root BSD-2-Clause license does not relicense those files. Modified 2026-11-06 for MoonBSDiff; source files carry modification notices.

This is a decoder-only subset, not a replacement bzip2 engine. The source lock gives original and adapted content hashes. The patch uses the original source as its old side and the local copied files as its new side; line endings are normalized to LF for the diff; apply it to the named original subset to reproduce the copied-file adaptations. New `bounded.mbt` implements the single-stream driver, budget and internal error bridge. New `moon.pkg` only imports core/debug. The encoder, writer and streaming Reader were not copied.

Changes: remove unused writer/sink and original one-shot driver; substitute a local error type; pass a Meter into read_block; reserve before RLE output; reject four-byte RLE runs missing their count; use subtraction for intermediate run bounds. The new driver verifies the combined CRC and computes its logical bit position for exact single-stream consumption. Huffman, MTF, inverse BWT, CRC and randomisation algorithms are preserved.

Package exports are implementation plumbing, not root-library API. They must not be treated as stable external APIs. `Budget.emitted` counts reserved/produced bytes across intervals and can also prove that failures stop before a disallowed RLE segment. `Decoded.blocks` counts actual parsed blocks, not byte-pattern matches. No public root debugging API was added.
