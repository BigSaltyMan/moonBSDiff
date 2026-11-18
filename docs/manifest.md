# External content manifests

This CLI feature is not part of published 0.1.0. The patch remains plain
BSDIFF40: no custom header, trailer or embedded JSON. Commit 20 adds bounded manifest reading, verify, and checked patch delivery.
Use a trusted manifest. Choose the command according to how you need to handle
the restored bytes.

~~~sh
moonbsdiff verify --manifest update.json old.bin update.patch
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin
~~~

Ordinary verify restores in memory. Streamed verify uses private copies of the
inputs and discards each restored chunk after hashing. Streamed patch stages the
restored file for checked delivery. The two streamed manifest commands require a
CLI built with these changes and are absent from the public v0.4.0 archives.
[File application and resource limits](file-apply.md#streaming-verification-unreleased).

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

## Select a patch for the installed version (Unreleased)

When several trusted manifests describe updates to the same target, pass the
installed file and the candidate manifests in preference order.

```sh
moonbsdiff manifest select installed.bin v1-to-v3.json v2-to-v3.json
```

The command reads the old file once and computes its SHA-256 once. It reads
each manifest within the 16 KiB cap and checks the schema and declared limits.
All candidates must agree on both target size and target SHA-256. A candidate's
`old` must match the installed file by size and hash. Among those matches,
the smallest declared `patch.size_bytes` wins. Equal sizes favor the first
argument. Success writes one JSON object to stdout and exits `0`.

This response was produced by the command above with old versions `ABCDE` and
`ABXDE` and the common target `prefix-ABCDE!`. The installed bytes were `ABXDE`.

```json
{
  "schema_version": 1,
  "manifest_path": "v2-to-v3.json",
  "patch": {
    "size_bytes": "138",
    "sha256": "d76b2e40a6d6bbebf10d76f65ce276993fe270090fbc7bf78154a4ecb706dfef"
  },
  "new": {
    "size_bytes": "13",
    "sha256": "909d4a1c494cec5f86a7518e74ecf70e5b4e9fb909003c15c9d121f6f938f89d"
  }
}
```

The response preserves the path passed on the command line. Use your update
catalog to locate the patch associated with that manifest. After downloading
the patch, check the declared size and SHA-256 against `patch`, then pass the
original selected manifest to streaming verification or checked delivery.

```sh
moonbsdiff verify --stream --manifest v2-to-v3.json installed.bin v2-to-v3.patch
moonbsdiff patch --stream --manifest v2-to-v3.json installed.bin v2-to-v3.patch restored-v3.bin
```

Selection only reads the installed file and candidate manifests. Use trusted
manifests and verify the downloaded patch before installing its target. The
existing verification and delivery commands also recheck the actual old file.

The defaults match CLI application limits. Only `--max-old-bytes`,
`--max-new-bytes`, `--max-output-bytes`, and `--max-patch-bytes` are applicable.
Put options before paths or use `--` before a path beginning with `-`. A missing
match, mixed target, invalid manifest, read error or cap violation exits `1`
with a diagnostic on stderr and empty stdout. Missing arguments and inapplicable
options exit `2`. This command requires a CLI built from source containing this
change. The published 0.4.0 CLI predates it.

## Plan a multi-hop update (Unreleased)

Use a trusted target manifest to identify the final bytes. Pass trusted
candidate manifests after the installed file, in the desired traversal order.

```sh
moonbsdiff manifest plan --target-manifest v2-to-v3.json installed.bin v1-to-v2.json v2-to-v3.json v1-to-v3.json
```

The planner reads the installed file once and computes its SHA-256 once. It
applies the same 16 KiB cap, strict schema, and declaration limits as
`manifest select` to the target and every candidate manifest. The same four
byte-limit options apply. Only positional manifests supply directed edges.
The target manifest identifies the destination by `new.size_bytes` and
`new.sha256`, and it can also be supplied as a positional candidate.

A route minimizes the sum of declared patch bytes, then the step count.
The planner visits outgoing edges in positional order. At equal cost and step
count it processes the earliest queued state first and retains the first route
to an identity at that score. Two versions join only when both size and SHA-256
agree. A route can use several versions even when their byte counts are equal.

This example used the `testdata/upstream/seeded-random` old and new files as
v1 and v2. The fixture flips the last bit of v2 for v3. The deliberate
full-target direct patch was 2532 bytes. The tested command produced this
response, pretty-printed for readability.

```json
{
  "schema_version": 1,
  "start": {
    "size_bytes": "2048",
    "sha256": "3f1dc5983729c3316f87f580ef435e68507120b7bde1a52f15dbbc93169751d8"
  },
  "target": {
    "size_bytes": "2048",
    "sha256": "66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6"
  },
  "total_patch_bytes": "368",
  "steps": [
    {
      "manifest_path": "v1-to-v2.json",
      "old": {"size_bytes": "2048", "sha256": "3f1dc5983729c3316f87f580ef435e68507120b7bde1a52f15dbbc93169751d8"},
      "new": {"size_bytes": "2048", "sha256": "ec7c875b594819312410388bd93805e989e4dba1cc68f793ece69352bfe8d6f5"},
      "patch": {"size_bytes": "204", "sha256": "b48d5bd790a5a37b507603284b501f21a6c15c110e96c6cabecd1867f705927b"}
    },
    {
      "manifest_path": "v2-to-v3.json",
      "old": {"size_bytes": "2048", "sha256": "ec7c875b594819312410388bd93805e989e4dba1cc68f793ece69352bfe8d6f5"},
      "new": {"size_bytes": "2048", "sha256": "66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6"},
      "patch": {"size_bytes": "164", "sha256": "3470eb1ac7e7d52c7402d5ee6d142132760e079ba524f8aca8f3bf279959e57e"}
    }
  ]
}
```

The cost comes from the trusted manifest declarations. The caller looks up
and downloads the patches, then applies each step with its original manifest.
Use a separate output for each step and pass that file as the next step's old
input. Both commands below succeeded in the test, and `restored-v3.bin` matched
the independent 2048-byte target byte for byte.

```sh
moonbsdiff patch --stream --manifest v1-to-v2.json installed.bin v1-to-v2.patch restored-v2.bin
moonbsdiff patch --stream --manifest v2-to-v3.json restored-v2.bin v2-to-v3.patch restored-v3.bin
```

If the installed identity already equals the target, success reports
`"total_patch_bytes": "0"` and an empty `steps` array. The candidate list can
be empty. All supplied manifests still need to pass preflight. An unreachable
target, read or manifest error exits `1` with a diagnostic and empty stdout.
Invalid arguments exit `2`. This command requires a CLI built from source
containing this change. The published 0.4.0 CLI predates it.

## Apply a local patch chain (Unreleased)

First obtain the route for the installed file, then fetch the patches through
your update catalog. Supply the local patch and its original manifest for each
step in the plan's order.

```sh
moonbsdiff manifest plan --target-manifest v2-to-v3.json installed.bin v1-to-v2.json v2-to-v3.json
moonbsdiff patch-chain --target-manifest v2-to-v3.json -- installed.bin restored.bin v1-to-v2.patch v1-to-v2.json v2-to-v3.patch v2-to-v3.json
```

This uses the two-hop fixture from the planning section. A single chain call
delivered `restored.bin` with all 2048 bytes matching the independent target.
The source files and both patches remained unchanged. The target manifest may
also be the last step's manifest. If `manifest plan` returns an empty route,
the installed file is already the target and the caller can skip recovery.

`patch-chain --target-manifest FILE [LIMITS] OLD OUTPUT (PATCH MANIFEST)...`
requires at least one complete pair. The application limits accepted by
`patch --stream` apply. Put options before paths and use `--` before a path
starting with a hyphen. Use trusted manifests. Each manifest goes through the
16 KiB read cap and strict schema checks. The command retains the validated
identities for this call and checks every link and the final target, matching
both size and SHA-256 before any patch is applied. The actual output path
must be fresh and distinct from the inputs. The final publication again
checks for a competing destination and never replaces it.

The first old file and each patch are copied into private files while being
hashed. Each step decodes from verified handles using at most 4096 bytes per
stream read or write, then checks the streams, restored size and SHA-256.
An intermediate stays private and becomes the next old input by handle once
verified. Only the last output can be published to the named destination.

Byte caps, the expanded-byte budget and the instruction budget apply afresh to
each step. At most the current old input copy or intermediate, the current
patch copy and the next private output are needed together. The current old
and patch handles are closed before advancing. Private copies use Windows
temporary storage or Linux `/tmp`, and final staging uses the destination
directory. Total work grows with the number and sizes of the steps, and the
same destination filesystem requirements as streaming patch still apply.

By default, success is silent and exits `0`. Invalid arguments exit `2`. Failure exits
`1` with a diagnostic on stderr that names the step when applicable. Ctrl+C
uses one cancellation session for the chain. Confirmed cancellation before
the final publication gate exits `130` and releases the private files. An
error after publication can leave the fully verified final file in place.
The published 0.4.0 CLI predates this command.

### Chain progress on stderr

```sh
moonbsdiff patch-chain --progress json --target-manifest v2-to-v3.json -- installed.bin restored.bin v1-to-v2.patch v1-to-v2.json v2-to-v3.patch v2-to-v3.json
```

Use `--progress text` for terminal output such as `step=2/2`. JSON mode
writes one schema 1 object per line to stderr. Stdout remains empty. Chain
events add a one-based `step` and an integer `step_count`; `step` is `null`
before an event belongs to a step. Each step resets `restored_bytes` to `"0"`
and `total_bytes` to `null` until the target size is known. Byte counts use
decimal strings. The single-hop `patch --stream` event schema stays the same.

Actual excerpt from the two-hop test:

```jsonl
{"schema_version":1,"event":"step_verified","stage":"validating","restored_bytes":"2048","total_bytes":"2048","output_committed":false,"message":"Intermediate verified and ready for the next step","step":1,"step_count":2}
{"schema_version":1,"event":"phase","stage":"preparing","restored_bytes":"0","total_bytes":null,"output_committed":false,"message":"","step":2,"step_count":2}
{"schema_version":1,"event":"phase","stage":"delivering","restored_bytes":"2048","total_bytes":"2048","output_committed":false,"message":"","step":2,"step_count":2}
{"schema_version":1,"event":"complete","stage":"complete","restored_bytes":"2048","total_bytes":"2048","output_committed":true,"message":"All checks and delivery completed","step":2,"step_count":2}
```

Reaching the byte total is followed by verification. `step_verified` marks
successful validation and transfer of a private intermediate. `delivering`
marks the start of final delivery. `complete` confirms publication and
successful cleanup. Failure or cancellation emits `error` or `cancelled` as
the terminal event. `output_committed` reflects whether final publication took
place, including when cleanup fails after publication.

## Verify a local patch chain (Unreleased)

Use `verify-chain` to check a planned route before distributing it. Supply the
installed file and at least one local patch and manifest pair in plan order.
Use a trusted target manifest, which may also be the last step's manifest.

```sh
moonbsdiff verify-chain --progress json --target-manifest v2-to-v3.json -- installed.bin v1-to-v2.patch v1-to-v2.json v2-to-v3.patch v2-to-v3.json
```

Both chain commands check every link against the next manifest and the last
step against the requested target. Each step checks all three compressed
streams, the restored size and SHA-256. Application limits apply to each
step, including the output byte limit for the final step.

Private input copies and intermediate versions still use temporary disk
space. The final step passes restored chunks of up to 4096 bytes to SHA-256
and discards them. It uses the stream decoder's block workspaces and
bounded transfer buffers throughout, and needs no final output path.

With the 2048-byte two-step fixture, stdout contains this one line on success.

```text
Chain verification succeeded: all steps match the supplied manifests.
```

Progress and runtime diagnostics go to stderr. Choose `--progress text` for
terminal output or `--progress json` for JSONL. Intermediate steps emit
`step_verified`. The final `complete` event confirms content verification
and cleanup. It has `output_committed: false`, and the chain has no
`delivering` phase. This is the actual terminal event from the fixture.

```jsonl
{"schema_version":1,"event":"complete","stage":"complete","restored_bytes":"2048","total_bytes":"2048","output_committed":false,"message":"Chain verification completed","step":2,"step_count":2}
```

Success exits `0`. Argument errors exit `2`. Runtime failures exit `1` and
confirmed cancellation exits `130`. Only a successful run prints the success
line. Ctrl+C (also Ctrl+Break on Windows) requests cancellation, checked
during processing and once more after closing the private inputs. The
published 0.4.0 CLI predates this command.

## Create a manifest for an existing patch (Unreleased)

Use `diff --manifest` when generating a new patch. Use `manifest create` when
you already have a BSDIFF40 patch and an independently obtained expected target.
Run this example from the repository root against the fixed BSDiff 4.3 fixture.
Choose a new output path if `update.json` already exists.

```sh
moonbsdiff manifest create testdata/upstream/replace/old.bin testdata/upstream/replace/new.bin testdata/upstream/replace/patch.bin update.json
moonbsdiff verify --stream --manifest update.json testdata/upstream/replace/old.bin testdata/upstream/replace/patch.bin
```

The command applies the supplied patch in memory and compares the entire
restored result with `NEW_FILE` before writing the manifest. The original patch
stays byte-for-byte unchanged. `patch.sha256` identifies that patch, and
`new.sha256` identifies the independently supplied target. In schema 1,
`producer` identifies the MoonBSDiff tool and version that wrote the manifest.
The original patch generator may be unknown.

Place application limits before the four paths. Supported options are
`--max-old-bytes`, `--max-new-bytes`, `--max-output-bytes`, `--max-patch-bytes`,
`--max-expanded-bytes` and `--max-controls`. The CLI uses the same defaults as
`patch`. The expected new file is subject to both target byte limits. Use `--`
before the paths if a name starts with `-`. The operation may hold the old file,
original patch, expected target and restored bytes in memory at the same time.
The old and expected new paths may refer to the same file.

The command writes only the manifest. Success is silent with exit `0`.
Invalid arguments exit `2`. Reading, applying, comparing or delivering the
manifest can fail with exit `1`. On apply or comparison failure no manifest
is delivered. Existing destinations, including links to inputs, are preserved.
`manifest create` requires a CLI built with these changes and is absent from
the public v0.4.0 archives. Use a trusted target and share the resulting manifest
through a trusted channel.

## Generate a patch bundle from MoonBit (Unreleased)

Import the root library and the manifest subpackage in `moon.pkg`.

```moonbit
import {
  "BigSaltyMan/moonbsdiff" @moonbsdiff,
  "BigSaltyMan/moonbsdiff/manifest" @manifest,
}
```

The publisher receives two read-only `Bytes` fields. It sends the standard
BSDIFF40 patch and the schema 1 manifest separately. The client takes the manifest
from a trusted channel and verifies the restored content.

```moonbit
fn publish_update(old : Bytes, new : Bytes) -> Result[@manifest.PatchBundle, @moonbsdiff.BsdiffError] {
  @manifest.diff(old, new, @moonbsdiff.Limits::for_diff())
}

fn restore_bundle(old : Bytes, patch : Bytes, trusted_manifest : Bytes) -> Result[Bytes, @manifest.ManifestError] {
  @manifest.apply(old, patch, trusted_manifest, @moonbsdiff.Limits::for_apply())
}

test "publish and restore in memory" {
  let old = b"abc\x00\xff"
  let new = b"abC\x00\xff!"
  match publish_update(old, new) {
    Ok(bundle) => assert_eq(restore_bundle(old, bundle.patch, bundle.manifest), Ok(new))
    Err(_) => abort("generation failed")
  }
}
```

`diff` uses the default generation options. `diff_with_options(old, new, limits,
options)` accepts the root library's `DiffOptions`. Both generate one patch and
return the root `BsdiffError` on failure. After generation succeeds, the manifest
hashes the two input buffers and the returned patch once each. That work is
additional to the sorting and matching budgets in `Limits`. The native CLI's
`diff --manifest` uses the same code and delivers the patch before the manifest.

These generation interfaces are available from this source change on native,
JS and Wasm-GC. The public Mooncakes 0.4.0 package predates them.

## Reuse one old version for multiple patch bundles (Unreleased)

Use the same `@moonbsdiff` and `@manifest` imports as in the example above.
Each call returns a bundle that can be sent or stored independently.

```moonbit
test "manifest public bundle index two targets" {
  let old = b"ABCDE"
  let new_a = b"ABXDE"
  let new_b = b"prefix-ABCDE!"
  let limits = @moonbsdiff.Limits::for_diff()
  let index = @manifest.BundleIndex::build(old, limits).unwrap()
  let bundle_a = index.diff(new_a, limits).unwrap()
  let bundle_b = index.diff(new_b, limits).unwrap()
  // Read the first bundle only after generating the second.
  let apply_limits = @moonbsdiff.Limits::for_apply()
  assert_eq(
    @manifest.apply(old, bundle_a.patch, bundle_a.manifest, apply_limits),
    Ok(new_a),
  )
  assert_eq(
    @manifest.apply(old, bundle_b.patch, bundle_b.manifest, apply_limits),
    Ok(new_b),
  )
}
```

`BundleIndex::build` retains the immutable old bytes and suffix array through
the root `DiffIndex`, together with the old length and SHA-256. It hashes the old
bytes once after the index builds successfully. No separate copy of the old
bytes or history of generated bundles is retained.

`index.diff` uses the default generation options. Use
`index.diff_with_options(new, limits, options)` to select a compression level.
Each target call revalidates its limits, including the old byte cap, and uses
fresh matching and generation budgets. Sorting work is charged at build time.
After generating each patch, the call hashes that target and patch. A failed
call leaves the index and previously returned bundles usable. Build and
generation return the root `BsdiffError` on failure.

Reuse saves repeated sorting and hashing of the old version. Actual time
depends on the inputs and options. This API is available from this source
change on native, JS and Wasm-GC. The public 0.4.0 package predates it.

## Verified restoration from MoonBit (Unreleased)

Applications can use the same schema 1 manifest emitted by `manifest create`
or `diff --manifest`. This API first appears in the source change that adds the
`manifest` subpackage. The public Mooncakes 0.4.0 package predates it.

```moonbit
import {
  "BigSaltyMan/moonbsdiff" @moonbsdiff,
  "BigSaltyMan/moonbsdiff/manifest" @manifest,
  "moonbitlang/core/debug" @debug,
}
```

```moonbit
fn restore_update(old : Bytes, patch : Bytes, trusted_manifest : Bytes) -> Result[Bytes, String] {
  match @manifest.apply(old, patch, trusted_manifest, @moonbsdiff.Limits::for_apply()) {
    Ok(restored) => Ok(restored)
    Err(IdentityMismatch(object=Old, ..)) =>
      Err("Installed bytes do not match the required old version")
    Err(error) => Err(@debug.to_string(error))
  }
}
```

`apply(Bytes, Bytes, Bytes, Limits) -> Result[Bytes, ManifestError]` runs on
native, JS and Wasm-GC. It holds the inputs and restored bytes in memory. It
validates `Limits`, checks the 16 KiB manifest cap before decoding UTF-8, then
checks the schema and declared sizes. It checks actual lengths before hashing
their bytes and uses the same verified input buffers for restoration. The
restored bytes are returned only after their length and SHA-256 match. Supply
the expected manifest through a trusted channel to establish the expected content.

| Error variant | What the caller can inspect |
| --- | --- |
| `InvalidLimits` | Original configuration `BsdiffError` |
| `InvalidEncoding`, `InvalidJson`, `InvalidSchema` | Stage of manifest rejection. JSON reports the key for duplicates and schema errors report the applicable field. |
| `LimitExceeded` | Named cap, requested value, and actual limit |
| `IdentityMismatch` | `Old`, `Patch`, `PatchTarget` (header declaration), or `Restored`, with `Size` or `Sha256` as the difference |
| `HeaderError`, `ApplyError` | Original `BsdiffError`, including kind, stage, and location where available |

The native CLI shares the schema and size preflight. Its in-memory commands
also share checked restoration. Streaming commands retain bounded, file-based
reads, private input copies and incremental hashing.

Callers that acquire input bytes after reading a manifest can use `prepare`
first. Its `PreparedManifest` exposes read-only declared identities and keeps
the checked limits. `PreparedManifest::restore` verifies the inputs and result
using those limits. Successful preflight alone checks declarations.

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
version from the shared constant generated from `moon.mod`; the consumer
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
channel. The Commit 20 implementation described above covers memory-based
verification. These CLI 0.2.0 additions are absent from published Mooncakes 0.1.0;
Mooncakes 0.2.0 has not been published.
