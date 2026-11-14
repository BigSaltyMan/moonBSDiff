# External content manifest (CLI 0.2.0)

This CLI feature is not part of published 0.1.0. The patch remains plain
BSDIFF40: no custom header, trailer or embedded JSON. Commit 20 adds bounded manifest reading, verify, and checked patch delivery.
Signatures, network fetching, automatic updates and streaming remain unimplemented.

```sh
moonbsdiff diff --manifest update.json old.bin new.bin update.patch
```

Diff uses --manifest as output; patch and verify use it as input as described below.
Options precede operands and -- ends options for
leading-hyphen input/output names. The manifest flag takes one nonempty path value;
a leading-hyphen manifest name must use ./-name, since -- terminates options only
for positional operands. Duplicate/missing/inapplicable flags and combining
--manifest with --show-limits exit 2 before IO. Existing limit overrides still
apply. Without this flag diff emits no manifest and plain patch retains its original
unchecked-identity behavior. Success is silent on stdout/stderr, exit 0;
operational/output failures use stderr and exit 1.

## Schema 1 and real example

Historical Commit 19 capture from the command above with old bytes abc/00/ff (5 bytes) and new bytes
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
(string BSDIFF40), producer, old, new, patch. The generator emits producer name=moonbsdiff and
version from the actual generated cli_version/module build metadata; the consumer
treats those required strings only as provenance information. The historical example above reports that build's 0.1.0 metadata; CLI 0.2.0 now
reports 0.2.0 from the same generated module source. No unverified source SHA is
embedded. GitHub CLI distribution is distinct from the immutable published
Mooncakes 0.1.0 artifact; Mooncakes 0.2.0 is not published.

Each content entry has size_bytes as a nonnegative decimal **string**, and sha256
as exactly 64 lowercase hexadecimal digits (full SHA-256). Zero denotes actual
empty content, not an unlimited setting. No timestamps, randomness, machine paths
or IO-authorizing paths are stored. Object keys are emitted in the fixed order
shown, with compact standard JSON serialization and one final LF. Same content,
producer metadata and produced patch give identical manifest bytes. No guarantee
is made that different generator/tool versions produce identical patches.

The patch size excludes this separate JSON file. This is a content binding schema,
not an inspect report: it makes no claim about CRC or instruction validation. A
bounded consumer validates schema/format, exact field types and integer/hash syntax
before using any values; see the Commit 20 input policy below.

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
Linux delivery now uses the primary or [guarded compatibility policy](linux-delivery.md); no unsafe rename fallback,
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
update system. Bounded content verification and checked restoration are provided below; neither authenticates a publisher.

## Bounded consumption and checked restoration (Commit 20)

```sh
moonbsdiff verify --manifest update.json old.bin update.patch
moonbsdiff patch --manifest update.json old.bin update.patch restored.bin
```

All options precede operands, -- still permits leading-hyphen operand names, and
a leading-hyphen manifest value uses ./-name. Verify requires --manifest and
exactly two input operands; no final output operand is accepted. Patch accepts
an optional manifest and exactly three operands. Diff generation and inspect
remain separate: inspect accepts no manifest or --deep mode. Verify accepts the
same meaningful application caps as patch (old/new/output/patch/expanded/control),
rejects sorting/matching, --json and --show-limits, and introduces no new config
file, environment priority or library default. Default application policy remains
for_apply with the CLI patch cap of 128 KiB. Producer metadata never selects a
code path, grants trust, or authorizes file reads.

### Input schema and parser policy

Manifest input is a regular file bounded to **16384 bytes** by the existing native
reader, both before known-size allocation and during accumulated reads. This cap
is fixed, not affected by --max-patch-bytes or an unlimited sentinel. The normal
405-byte output fits it. Standard core/encoding/utf8 decoding is strict; invalid
UTF-8 and a leading BOM are rejected. Standard core/json parses with
max_nesting_depth=8, reject_duplicate_keys=true and preserve_number_repr=true.
The fixed SDK's parser checks duplicates while parsing, before keys are lost to
an object map; decoded equivalents such as size_bytes and \u0073ize_bytes are
also duplicates. **All duplicate keys at every depth are rejected.**

The six root fields and each producer/content object's exact fields are required.
**Unknown fields are rejected at every object level**, including proposed paths
or extensions; they never drive IO. Schema version is the integer literal 1,
not 1.0, an exponent or a string. Format must be BSDIFF40. Producer name/version
must be strings but are opaque information; a different/unknown producer version
is not automatically rejected or trusted. Each size is a nonempty ASCII decimal
string in 0..9223372036854775807, checked before multiply/add and never converted
through floating point. Leading zeros are accepted. The literal "0" is valid for
empty content and is unrelated to the strictly positive Limits settings. Hashes
must be exactly 64 lowercase ASCII hex digits; absent/wrong-type/uppercase/invalid
hashes fail. This consumes the unchanged Commit 19 schema rather than creating a
new manifest format or rewriting expected values.

### Shared pipeline and delivery

Verify and patch --manifest call the same verified_restore function:

1. Bounded-read and strictly parse the manifest.
2. Check declared old and patch sizes against their effective input caps; check
   new size against both max_new_bytes and max_output_bytes before reading inputs.
3. Bounded-read the actual old/patch buffers; check both exact sizes and SHA-256.
   A size/hash mismatch stops before header parsing or apply.
4. Reuse inspect_header for structural checks and compare its declared target
   size to the manifest. Header-only inspection is not accepted as full validation.
5. Call the public apply with those **same immutable Bytes** and effective Limits.
   No hash-path/reopen gap exists. Apply retains its CRC/control/consumption and
   expanded/instruction checks. A corrupt payload with an updated manifest hash
   still fails here.
6. Compare restored byte size and SHA-256 to the manifest's original new identity.

Verify discards the restored buffer, creates no output/temporary-delivery file
and on success prints:

```text
Verification succeeded: manifest, inputs and restored content match (not publisher authentication).
```

It really restores into bounded memory: this is not header-only, zero-memory or
streaming verification. Concurrent writes during the initial read remain outside
a filesystem-snapshot guarantee; the bytes actually checked are exactly those
used in apply. The expected new identity comes from the supplied manifest, never
from regenerating it using the restored result.

Patch prechecks the output against old, patch and manifest with the existing
native identity/no-existing-target check (including aliases), then calls the
shared pipeline. **Only after every check succeeds** does it call the unchanged
no-overwrite delivery function. Validation failure never calls delivery, writes
inputs or creates a final output. Operational delivery failures keep the existing
semantics; a post-link close error can leave an output visible, so a failure is
not a power-loss/rollback guarantee. Linux uses the [primary/guarded compatibility
policy](linux-delivery.md). Plain patch without --manifest still cannot reliably identify a wrong old
file, and diff's optional two-output non-transactional contract is unchanged.

Success exits 0 (checked patch stays silent). Parameter/configuration problems,
including missing verify --manifest, exit 2. File/encoding/JSON/schema/declaration/
identity/header/apply/restored-content/delivery failures exit 1 with a stage and
content-specific stderr diagnostic. Failures leave stdout empty, never a partial
success report. No JSON event/progress output is added.

### Directed evidence

The retained [Commit 19 sample](../testdata/manifest/README.md) supplies fixed old,
new, patch and manifest bytes. New tests perform no diff or oracle generation.
Windows/Linux each passed five new tests / 44 calls without skips: correct verify
and checked delivery including empty files, 16 KiB exact/over-limit reads,
pre-apply input mismatch, header/new-size mismatch, wrong restored hash, actual
apply rejection, strict schema/types/numbers/duplicates/depth/UTF-8, ignored
producer-version authority, custom caps before missing input opens, and preservation
of existing outputs/manifest hard-link aliases. Inputs, contents and mtimes stay
unchanged; verification creates no file. Commit 19's obsolete patch-inapplicable
argument assertion is now a missing-value assertion because that flag is valid.
Existing CI platform builds append only this collection; locally the old CLI/IO,
full library/interoperability matrices, probes and resource measurements were not
rerun. Root .mbti, default factories, native IO and dependencies are unchanged.

Content consistency against a supplied manifest still does not authenticate its
publisher. If an attacker replaces both patch and expected manifest, ordinary
hashes do not supply authenticity. Expected manifests must come from a trusted
channel. There is no signature, network acquisition, automatic update or streaming
promise. These CLI 0.2.0 additions are absent from published Mooncakes 0.1.0;
Mooncakes 0.2.0 has not been published.
