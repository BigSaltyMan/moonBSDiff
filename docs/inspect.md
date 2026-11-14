# Header-only patch inspection (CLI 0.2.0)

These CLI additions are not in published 0.1.0. They inspect the
BSDIFF40 header and compressed intervals only. There is no --deep mode, manifest
verification, old-file identity check, decompression or restoration in this step.
A successful exit is not a claim that the patch is valid or can be applied.

## Commands and read policy

```sh
./_build/bin/linux/moonbsdiff inspect testdata/upstream/replace/patch.bin
./_build/bin/linux/moonbsdiff inspect --json testdata/upstream/replace/patch.bin
./_build/bin/linux/moonbsdiff inspect --max-patch-bytes 256KiB testdata/upstream/replace/patch.bin
```

The Windows executable uses the same arguments. Only --json (no value) and
--max-patch-bytes VALUE are accepted. Options precede the single patch path;
-- ends option parsing and allows a leading-hyphen path. Duplicate, unknown or
inapplicable options, missing values/paths and extra paths exit 2. In particular,
old/new/output/expanded/control/sort/match overrides and --show-limits are not
applicable to inspect. Diff/patch reject --json at this stage; their behavior and
effective-limit display otherwise stay unchanged.

The default patch read cap is 131072 bytes, matching the existing CLI patch-input
cap. Values reuse the checked Commit 17 syntax: positive ASCII decimals with an
optional case-sensitive B, KiB (1024), MiB (1048576), no signs/spaces/fractions.
The effective cap must be in 1..2147483647, validated before native narrowing/IO.
Known and growing file sizes are bounded by the existing regular-file reader.
The full bounded patch buffer is read; this is not a streaming header reader or
a consistent snapshot guarantee under concurrent file mutation.

No output or delivery file is created, and the CLI does not require an old file.
Header/range checks cover 32-byte availability, exact magic, sign-magnitude
integers including negative zero, nonnegative lengths/target size, checked Int64
boundary sums and physical interval bounds. No output buffer is allocated from
the declared target size. Inspection deliberately applies no restored-output-size
policy: even 9223372036854775807 may be reported from a tiny legal header. This
neither expands apply defaults nor establishes that such a target is applicable.

Success writes one complete text or JSON result to stdout, exits 0 and leaves
stderr empty. Parameter/configuration failures exit 2; read or format failures
exit 1. Diagnostics go to stderr, with no partial success result on stdout.

## Actual text example

Captured using the first command above with the existing 134-byte upstream
replace fixture; no fixture was regenerated:

```text
Format: BSDIFF40
Patch bytes: 134
Declared restored bytes: 20
Control compressed range: start=32 length=45 bytes
Diff compressed range: start=77 length=43 bytes
Extra compressed range: start=120 length=14 bytes
Validation: header-only
Compressed streams / CRC: not checked
Control instructions: not checked
Restoration: not checked
Identity: not checked
```

## Actual JSON example and schema version 1

The second command produced the following object (pretty-printed here only for
readability; JSON member order and whitespace are not protocol requirements):

```json
{
  "schema_version": 1,
  "format": "BSDIFF40",
  "patch_path": "testdata/upstream/replace/patch.bin",
  "patch_bytes": "134",
  "new_bytes": "20",
  "validation": "header-only",
  "compressed_ranges": {
    "control": {
      "start_bytes": "32",
      "length_bytes": "45"
    },
    "diff": {
      "start_bytes": "77",
      "length_bytes": "43"
    },
    "extra": {
      "start_bytes": "120",
      "length_bytes": "14"
    }
  },
  "checks": {
    "compressed_streams": "not-checked",
    "crc": "not-checked",
    "control_instructions": "not-checked",
    "restoration": "not-checked",
    "identity": "not-checked"
  }
}
```

| Field | Type / meaning |
| --- | --- |
| schema_version | JSON integer 1 |
| format | String BSDIFF40 |
| patch_path | Correctly JSON-escaped input argument, not a canonical identity |
| patch_bytes | Decimal string: actual bounded patch buffer byte count |
| new_bytes | Decimal string: declared restored byte count; not allocated/verified |
| validation | String header-only |
| compressed_ranges | Object with control, diff, extra intervals |
| compressed_ranges.*.start_bytes | Nonnegative decimal string, zero-based patch offset |
| compressed_ranges.*.length_bytes | Nonnegative decimal string, length, not end offset |
| checks | Object with compressed_streams, crc, control_instructions, restoration, identity, each the string not-checked |

All byte counts/offsets and the Int64 declaration are lossless decimal **strings**,
never doubles. schema_version alone is numeric. Intervals are half-open from start
to start+length; the extra interval consumes the patch remainder. No decoded byte
counts/instruction statistics are emitted: unperformed work is not represented by
zero. Zero lengths or new_bytes="0" are genuine header/range facts, not successful
stream validation. Consumers must check validation/checks and must not infer full
verification from exit 0. The standard core/json AST serializer handles paths,
Unicode, backslashes, quotes and control-character escaping; user input is not
concatenated into JSON text. JSON schema 1 describes this command only, not a
future diff/patch JSON protocol or manifest format.

## Parser reuse and API review

The original private parse_header wrapper still validates Limits and the
application output-size cap in the original order. Structural checks moved to a
single private parse_envelope function shared by apply and inspection; integer
encoding/decoding and error offsets are unchanged. This avoids a second parser
or unnecessarily applying an output allocation policy to read-only metadata.

CLI packages cannot call root-private functions, so the root adds the minimal
`inspect_header(Bytes, Int64) -> Result[PatchInfo, BsdiffError]` and read-only
PatchInfo fields: patch_bytes, new_bytes, control_start, control_length,
diff_start, diff_length, extra_start, extra_length (all Int64). It accepts a
positive Int-indexable patch cap, checks the envelope, and returns scalar metadata;
it does not expose internal PatchRanges or decoder/debug state. It receives an
already-allocated Bytes buffer: callers must bound their own acquisition, as the
CLI does. Existing diff/apply signatures, limit factories and compression
dependencies are unchanged. CLI alone imports the existing toolchain core/json.

## Directed evidence and limits

`python scripts/test_cli_inspect.py --exe PATH_TO_CLI` reuses the existing CLI
file/exit helper but selects only five new contracts (30 calls): fixed nonempty
text/JSON, empty target/corrupted compressed content, maximum Int64 and escaped
paths, format/read-cap failures, and argument failures. Inputs are fixed upstream
fixtures or independently constructed sign-magnitude headers, not diff output.
Each invocation checks no files/content/mtime are changed or created. A fixture
whose entire compressed payload is zero still succeeds at header-only inspection
with every deeper check marked not-checked. Malformed-header errors check their
specific category, Header stage and appropriate field/offset; failed stdout is
empty. The public read-only API test and seven existing native format cases cover
the shared-parser change. No oracle, old CLI suite, full library/interoperability
matrix, resource measurement or large compression sample is rerun locally.

The normal CI reuses both platform CLI builds and appends only this new CLI
collection. Later commits may add manifest/deeper validation; none is asserted
here. Linux primary/guarded compatibility conditions apply to diff/patch output
delivery ([design](linux-delivery.md)), not inspect: inspect never invokes delivery.
