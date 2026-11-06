# BSDiff 4.3 test oracle

`upstream.lock.json` fixes source archives, sizes, SHA-256, principal BSDiff file hashes, and build flags. No Git revision is claimed. `download-record.json` records the actual acquisition: official BSDiff download failed and the verified Debian original archive was used. bzip2 1.0.8 was obtained from sourceware.org. Cached archives are hashed and size checked on every build; a corrupt cache or mismatched download is an error. Archives, extracted sources and binaries stay in ignored `_build/oracle`.

Verified environment: Ubuntu 24.04 under WSL2, Linux x86_64, GCC 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1), Python 3.12.3, GNU make and source-built static bzip2 1.0.8. The installed bzip2 command alone had no development headers. This recipe builds the dependency locally without installing system packages. No Windows-native or other-platform oracle build is claimed.

From repository root in WSL/Linux:

```sh
python3 tools/oracle/build.py
python3 scripts/generate_reference.py --generate
python3 scripts/generate_reference.py
python3 -m unittest discover -s scripts -p test_reference.py
```

From PowerShell, use `wsl -d Ubuntu-24.04 -- bash -lc 'cd /mnt/d/project/moonBSDiff && python3 tools/oracle/build.py'`, then run generation within that same WSL environment. Build requires GCC, make and Python 3.12 or newer. Downloads require network on the first run. Ordinary fixture verification requires only Python, and works offline on Windows or Linux.

`verified-build.json` is the actual 2026-11-06 build evidence: OS/architecture, compiler version, bzip2 runtime version, commands, library and executable hashes. Each new build writes its own `_build/oracle/build.json`; generation verifies its lock and executable hashes. GNU feature macro `-D_DEFAULT_SOURCE` exposes the original `u_char`/POSIX declarations. `-O2` enables optimization. No source adaptation patches were required: `adaptations` is empty, and no algorithm or format code was changed. BSDiff and bzip2 source files are extracted unchanged from the verified archives. The exact link inputs and bzip2 flags are recorded in the build evidence.

BSDiff license/Colin Percival copyright is retained in `BSDIFF-LICENSE.txt`, bzip2's complete distribution notice in `BZIP2-LICENSE.txt`. These test programs are independent of the MoonBit library and are never called by it. The historical C tools are for legal input comparisons; malformed input safety is defined independently by MoonBSDiff.
