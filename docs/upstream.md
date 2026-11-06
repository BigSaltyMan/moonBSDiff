# Sources and licenses

BSDiff 4.3 by Colin Percival is the planned algorithm and format reference; no algorithm has been ported yet. [Author page](https://www.daemonology.net/bsdiff/) and [Debian original archive](https://deb.debian.org/debian/pool/main/b/bsdiff/bsdiff_4.3.orig.tar.gz). The archive was independently downloaded and SHA-256 verified as `18821588b2dc5bf159aa37d3bcb7b885d85ffd1e19f23a0c57a58723fea85f48`. The `bsdiff.c` notice, retained for future reference and porting, is:

```text

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

```

`moonbitstack/moonzip@0.3.5` is Apache-2.0, from [moonzip](https://github.com/moonbitstack/moonzip); its installed version's LICENSE and moon.mod were checked. Its resolved dependencies are moonbase 0.4.2, mooncrypt 0.4.7, moondate 0.1.0 and moonseed 0.1.0; all five installed manifests declare Apache-2.0 and include LICENSE files; consult those files when redistributing. Decoder-only files are now attributed and adapted under `internal/bzip2/`; see its source lock, patch, and Apache-2.0 LICENSE. Python bz2 is used only for the test probe.

## Reproducible reference tools and fixtures

The fixed BSDiff 4.3 archive was downloaded again on 2026-11-06: 5740 bytes, SHA-256 `18821588b2dc5bf159aa37d3bcb7b885d85ffd1e19f23a0c57a58723fea85f48`. The official URL returned HTTP 403, and the Debian original-source mirror matched the lock. Principal `.c`, manual and Makefile content hashes are in [upstream.lock.json](../tools/oracle/upstream.lock.json); the `bspatch.c` format comment and both manuals are the format references. Source-built bzip2 1.0.8 is locked there separately and is used only by the C test tools, not as a new MoonBit dependency.

[Oracle build instructions and evidence](../tools/oracle/README.md) include the actual Linux/WSL environment, source acquisition, exact compile commands, unchanged-source status, copyright notices, and produced binary hashes. No platform patches were necessary. [Offline fixture documentation](../testdata/upstream/README.md) describes the 13 original-input cases and single manifest. Their upstream generation/application, same-environment reproduction and offline integrity checks passed. The core library never invokes Python or a C executable. MoonBSDiff application of upstream patches and upstream application of MoonBSDiff patches remain later acceptance gates.

## Commit 4 decoder adaptation

Compression still calls the installed `moonbitstack/moonzip@0.3.5` encoder. Bounded decoding uses a source subset copied from that exact installed package (its manifest was checked). [Source lock](../internal/bzip2/source-lock.json) records original per-file SHA-256 and adapted-file hashes; [changes.patch](../internal/bzip2/changes.patch) records the copied-source changes. `bounded.mbt` and the root adapter are new integration code. The cache itself was not changed. [Internal source notes](../internal/bzip2/README.md) explain scope and licensing.

The copied files retain Copyright 2026 Leo Cheng and Apache-2.0 notices. Their Apache-2.0 terms are retained in `internal/bzip2/LICENSE`; these files are not relicensed by the root BSD-2-Clause LICENSE. No upstream NOTICE file was present in the installed moonzip package. The original BSDiff reference, C-tool hashes and 13-fixture manifest are unchanged. The historical six-case level-1 dependency probe remains historical evidence; Commit 4's bounded-decoder results are separate in [compression.md](compression.md).
