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

`moonbitstack/moonzip@0.3.5` is Apache-2.0, from [moonzip](https://github.com/moonbitstack/moonzip); its installed version's LICENSE and moon.mod were checked. Its resolved dependencies are moonbase 0.4.2, mooncrypt 0.4.7, moondate 0.1.0 and moonseed 0.1.0; all five installed manifests declare Apache-2.0 and include LICENSE files; consult those files when redistributing. No dependency code is vendored here. Python bz2 is used only for the test probe.
