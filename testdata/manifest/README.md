# Fixed Commit 19 manifest example

The original Windows CLI example retained under ignored build output during
Commit 19 was recovered, not regenerated. It is the 5-byte old / 6-byte new /
153-byte patch / 405-byte JSON example documented at source
bdeaccd561e55a007283b08d2bd522791df851a8 in docs/manifest.md. The producing source
was that commit's implementation before its commit was created; producer.version
is its actual module metadata 0.1.0, not a claim that published 0.1.0 includes
manifest generation. All three identities were rechecked with independent Python
hashlib before copying these small artifacts. No oracle or diff was rerun to make
this fixture. Tests compare restoration to original new.bin, never to apply output.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| old.bin | 5 | `77cb6bea091ff250af304a09024b0c526be6a21014a91ab56e788c63a69e811f` |
| new.bin | 6 | `0ebd3565334ae7ea8506c274a03ecbec59d38ceef1191d7fd5fb4d1d08cde7d2` |
| update.patch | 153 | `50e7fad965f39f6a18ecc699e2e8b9b4b083e5544792473b2569ee4a9fb551b6` |
| update.json | 405 | `887eb07fa8cafcde084e6af2ce1968d3ce383ee1d79eed0ff497c3ad037a1047` |

Inputs were literal abc/00/ff and abC/00/ff/! fragments, where 00 and ff are
binary bytes and slashes merely separate the displayed fragments. Files use the
project's BSD-2-Clause terms. The additional empty-target test reuses the existing
upstream both-empty patch and independently hashes the original empty byte target;
it does not modify or regenerate that upstream fixture. Mutated manifests/patches
exist only in temporary per-test directories.
