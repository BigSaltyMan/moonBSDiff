# External content manifest (0.2.0 Unreleased)

This source-only feature is not part of published 0.1.0. The patch remains plain
BSDIFF40: no custom header, trailer or embedded JSON. There is no manifest reader,
verify, signature or manifest-checked restoration in this step (Commit 20 remains
pending).

```sh
moonbsdiff diff --manifest update.json old.bin new.bin update.patch
```

Only diff accepts --manifest. Options precede operands and -- ends options for
leading-hyphen input/output names. The manifest flag takes one nonempty path value;
a leading-hyphen manifest name must use ./-name, since -- terminates options only
for positional operands. Duplicate/missing/inapplicable flags and combining
--manifest with --show-limits exit 2 before IO. Existing limit overrides still
apply. Without this flag no manifest is allocated/hashed/written and the old
single-output path is unchanged. Success is silent on stdout/stderr, exit 0;
operational/output failures use stderr and exit 1.

## Schema 1 and real example

Captured from the command above with old bytes abc/00/ff (5 bytes) and new bytes
abC/00/ff/! (6 bytes), where / separates displayed fragments, not input bytes.
All sizes and hashes were independently checked with Python hashlib in testing.
The actual file is compact UTF-8 JSON plus one LF (405 bytes); pretty-printed here:

```json
{
  "schema_version": 1,
  "patch_format": "BSDIFF40",
  "producer": {
    "name": "moonbsdiff",
    "version": "0.1.0"
  },
  "old": {
    "size_bytes": "5",
    "sha256": "77cb6bea091ff250af304a09024b0c526be6a21014a91ab56e788c63a69e811f"
  },
  "new": {
    "size_bytes": "6",
    "sha256": "0ebd3565334ae7ea8506c274a03ecbec59d38ceef1191d7fd5fb4d1d08cde7d2"
  },
  "patch": {
    "size_bytes": "153",
    "sha256": "50e7fad965f39f6a18ecc699e2e8b9b4b083e5544792473b2569ee4a9fb551b6"
  }
}
```

Required top-level members are schema_version (JSON integer 1), patch_format
(string BSDIFF40), producer, old, new, patch. producer has name=moonbsdiff and
version from the actual generated cli_version/module build metadata. This checkout
still reports 0.1.0; the producer does not pretend this is released 0.2.0 or embed
an unverified source SHA. The checkout's unreleased features are distinct from
the immutable published 0.1.0 artifact.

Each content entry has size_bytes as a nonnegative decimal **string**, and sha256
as exactly 64 lowercase hexadecimal digits (full SHA-256). Zero denotes actual
empty content, not an unlimited setting. No timestamps, randomness, machine paths
or IO-authorizing paths are stored. Object keys are emitted in the fixed order
shown, with compact standard JSON serialization and one final LF. Same content,
producer metadata and produced patch give identical manifest bytes. No guarantee
is made that different generator/tool versions produce identical patches.

The patch size excludes this separate JSON file. This is a content binding schema,
not an inspect report: it makes no claim about CRC or instruction validation. A
future bounded parser must validate schema/format, exact field types and integer/
hash syntax before using any values; no such product input path exists yet.

## Hash implementation and data binding

CLI imports moonbitstack/mooncrypt/hash/sha2, explicitly selecting Sha256. The
installed mooncrypt 0.4.7 manifest and Apache-2.0 LICENSE were checked, as was the
attributed SHA-2 source. It was already resolved through moonzip; moon.mod now
pins it as a direct dependency because the CLI calls it directly. The resolved
versions remain moonzip 0.3.5, mooncrypt 0.4.7, moonbase 0.4.2, moondate 0.1.0 and
moonseed 0.1.0. No hashing implementation is copied or rewritten. No Python,
external hash command, network or file reopen occurs in product hashing. The
fixed empty and abc SHA-256 vectors test the selected engine and hex conversion.

After bounded input reads and successful public diff, make_manifest receives the
**same immutable old/new Bytes** that were passed to diff and the **same returned
patch Bytes** passed to delivery. Its signature accepts buffers, not paths. SHA-2
reads BytesViews, avoiding full input copies for hashing; only small digest/hex/
JSON objects are added. The expected new hash comes from original new input, not
apply output. Data-flow review confirms no path is re-read between generation and
hashing. Changes to disk after the bounded read cannot change these snapshots;
concurrent changes during the original read are still not a file-snapshot promise.

The original input/work/patch limits remain active. Hashing adds bounded linear
work over accepted buffers, outside the generator's logical work counters; this
is not a complete CPU, wall-clock or whole-process peak-memory guarantee.

## Preflight, delivery and partial failure

Before reading/generating, each output passes the existing input-identity and
no-existing-target check. A new **read-only** pair check then requires existing
directory parents and compares their actual file identities plus leaf names,
following directory aliases. It rejects identical targets through relative/absolute
paths, Linux symlink parents or Windows junctions. Windows conservatively compares
case-insensitively and strips trailing dots/spaces for comparison only (even for
case-sensitive/extended paths), and rejects alternate-stream leaf names. Names
used for delivery are never rewritten. Parent inspection does not prove future
writability or reserve the namespace; concurrent path changes are not a transaction.
Existing input/hard-link/output targets remain refused by the original check.

The order is:

1. Parse/validate effective limits, preflight both outputs and their distinction.
2. Bounded-read old/new, generate patch, compute all three hashes and serialize JSON.
3. Deliver patch using existing exclusive/no-replace delivery.
4. Deliver manifest with that same mechanism; only then return success.

**These files are not a cross-file atomic transaction.** If the second step of
delivery fails, exit 1 explicitly says patch delivered, manifest not completed,
no rollback attempted. The delivered patch remains. No caller path is deleted to
simulate rollback, no competing file is overwritten, and only owned temporary
objects are cleaned by the existing handle/anonymous-inode mechanism. A close error
after a final name is linked can leave that output visible despite failure; do not
infer absence of the manifest solely from a nonzero exit. Read the diagnostic,
check actual files and hashes, and choose unused output names or deliberately
handle existing files yourself before retrying. Repeating over a delivered patch
is refused rather than overwriting it.

There are no product filesystem writes beyond the existing deliver function.
Linux delivery still requires O_TMPFILE support and /proc; no unsafe fallback,
power-loss durability or broader platform promise is introduced.

## Validation scope and trust

The new CLI suite uses five tests. Windows has 22 CLI invocations (including three
Win32 name-alias checks), Linux 19; both pass without skips. Python hashlib checks
all three actual content hashes, empty/binary content, stable repeated manifests,
byte-identical patch output with/without the flag, argument errors, existing/input/
parent-alias conflicts and real second-delivery permission failure. A private
hash/buffer unit runs independently on both native hosts (one test, two fixed
SHA-256 vectors). The old IO runner now selects io_wbtest.mbt explicitly so its
nine IO contracts are not confused with the new hash unit; it still runs the same
old contracts in CI. Locally no old CLI/IO suite, full library/interoperability
matrix, large compression samples or resource measurements were rerun. CI reuses
the existing platform builds and appends only the new manifest CLI collection.

**A hash manifest checks content, not publisher identity. If both manifest and
patch are replaced, ordinary hashes do not provide authenticity. Obtain expected
manifests from a trusted channel.** This is not a signature or a safe automatic-
update system. Manifest validation and checked restoration remain Commit 20.
