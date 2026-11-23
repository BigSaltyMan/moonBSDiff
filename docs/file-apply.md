# File-based bounded patch application

This source-only native path is explicit:

```sh
python scripts/build_cli.py --release
./_build/bin/linux/moonbsdiff patch --stream OLD_FILE PATCH_FILE OUTPUT_FILE
# macOS (unreleased): ./_build/bin/macos/moonbsdiff patch --stream OLD_FILE PATCH_FILE OUTPUT_FILE
# Windows: .\_build\bin\windows\moonbsdiff.exe patch --stream OLD_FILE PATCH_FILE OUTPUT_FILE
```

Options precede paths, `--` ends options, duplicates fail. Existing application
limit options apply unchanged. For example, a patch larger than the CLI's default
128 KiB requires `--max-patch-bytes 256KiB` before the paths. Old/new/output,
expanded bytes and instruction caps remain independent; streaming does not widen
Limits' positive Int-indexable byte fields or alter the default factories.
Parameter/configuration failures exit 2; read/format/decode/execution/delivery
failures exit 1 on stderr; confirmed cooperative cancellation exits 130. Success
exits 0 and remains silent unless progress is explicitly selected.

Patch accepts `--stream`; the unreleased CLI also accepts it for verify.
The source supports [streaming with a manifest](#streaming-with-a-manifest-unreleased).
Without `--stream`, checked patch and verify bind hashes to the actual in-memory
bytes used by apply. This file path neither authenticates
old data nor claims a consistent input snapshot. File-only progress/cancellation
are described below; streaming generation and wall-clock deadlines remain
unsupported. Published CLI 0.2.0
assets and Mooncakes packages are unchanged.

## Feasibility and ownership

The original strict decoder accumulates the final RLE expansion and the complete
stream. The dependency Reader was not used: its semantics are not this adapter's
strict contract. The narrow adaptation retains the pinned Huffman/MTF/inverse-BWT
transform, separates its bounded RLE-domain block from final RLE emission, and
adds refillable Bits plus StreamReader. The original memory decoder uses that
same transform with its original whole-buffer RLE driver. See the attributed
[adaptation lock and patch](../internal/bzip2/README.md).

Three readers own independent absolute positions inside the Control, Diff and
Extra intervals. Each compressed refill is at most 4096 bytes and cannot cross
its interval. Pausing preserves bit accumulator, RLE-domain position, pending
run/value, block CRC, combined CRC and shared reservation accounting. Runs reserve
up to 259 expanded bytes before any output/CRC growth; pending output is emitted
in later bounded pulls without reserving it again. No prefix is decoded twice.
A reader that raised an error is discarded, never resumed.

The native adapter opens two regular input files, prechecks their measured sizes
against effective caps, and reads at most the 32-byte header prefix. Root
`inspect_header_prefix(header, actual_patch_bytes, max_patch_bytes)` reuses the
existing envelope parser without IO, target allocation, or stream validation.
The core library also exposes cross-target [`apply_stream`](apply.md#cross-target-streaming-application-apply_stream-unreleased)
(`StreamApplyStage`, `StreamApplyError`, `DeepPatchInfo`) in
`BigSaltyMan/moonbsdiff` for Native, JS, and Wasm-GC, and the native CLI
streaming path uses `apply_stream` directly with native file-handle callbacks
(retaining native file IO strictly inside `cmd/main`).

Old-file reads use checked absolute Int64 offsets with 64-bit `off_t` on POSIX
(Linux and macOS, compile-time `_Static_assert(sizeof(off_t) >= 8)`) or
`LARGE_INTEGER` on Windows. Read lengths are at most
4096 and checked against the opened size before seek/pread. A negative cursor is
never narrowed or negated until a chunk overlap proves it lies in -4096..-1.
Outside-old bytes contribute zero, addition is modulo 256, and x/y/output/cursor
advancement is checked before the corresponding action. Zero-output triples are
legal; instruction count is checked before fetching each triple.

## Retained buffers and budgets

| Object | Logical bound |
| --- | --- |
| Header/control triple | 32 / 24 bytes |
| Compressed input refill | 4096 bytes per reader |
| Final decoded pull | 1..4096 bytes; control reads require exactly 24 |
| Old-file read / output write | At most 4096 bytes each |
| Retained RLE-domain block | At most 100000 * stream level bytes per reader (900000 max) |
| Active block transform | BWT symbols, inverse permutation, intermediate plain arrays: each at most 100000 * level entries; bounded tables/selectors |

All three readers can retain a block concurrently. Only one block transform runs
at a time; scratch arrays and conversion copies can coexist with the other
readers' retained blocks. Chunk assembly also creates bounded Array/Bytes copies.
There is no array sized by restored-file size or whole decoded control/diff/extra
length. No whole patch is read, including during header parsing. The process and
runtime may retain freed allocations; these are logical structure bounds, **not
measured peak process memory**. RSS and reliable peak memory were **not measured**.

All readers share one cumulative expanded-byte budget. Each also enforces a
stream-output cap: diff/extra at declared target size, controls at
min(Int.max, 24 * instruction cap), with multiplication guarded before conversion.
Internal zero remaining permits only zero expansion. The target is checked against
both max_new_bytes and max_output_bytes before temporary output creation.
Control count and decoded budgets are never reset on block/stream switches.
Bzip2 internal CPU is not a complete work/time budget. Format-bounded block
workspace may be allocated even when little decoded budget remains.

## Strict completion and safe delivery

Reaching declared output size is insufficient: each reader is pulled again to
force final block CRC, actual end marker, combined CRC and exact compressed
interval consumption. Remaining decoded control, diff or extra bytes fail.
Only final-byte padding bits are ignored, as in memory apply; garbage and a
second stream are rejected. Empty targets undergo the same completion checks.
Invalid data may have written temporary bytes before a late CRC failure, but
those bytes are never published as a successful output.

The file layer calls the existing delivery function with a synchronous populate
callback. This follows the documented MoonBit native FuncRef/closure adapter
[ABI](https://docs.moonbitlang.com/en/stable/language/ffi.html#callbacks), validated
with the fixed compiler, rather than relying on a private closure layout.
Population, all format checks and input-handle closing happen before writer
closing and no-replace publication. A callback error, read error, write error or
input/writer close error prevents publication. Temporary creation failure closes
inputs even if the callback was never invoked. Context is single-operation native
CLI state, cleared after the synchronous call; no concurrent/reentrant API is
promised.

Windows retains handle-based exclusive creation, close-before-no-replace rename
and identity-based cleanup. Linux retains O_TMPFILE/proc first, and only its
existing capability branches use the guarded ext-filesystem private-directory
fallback. macOS (`apple_deliver`) requires a protected output parent directory
(`euid` or `root` owner, sticky bit if group/world-writable), creates a random
`0700` private directory via `arc4random_buf` + `mkdirat`, writes an exclusive
`0600` `payload` (`O_CREAT|O_EXCL|O_NOFOLLOW`), and publishes with non-replacing
`linkat`. See [Linux delivery](linux-delivery.md) for permission/threat assumptions
and possible retained objects when ownership cannot be proved. Final paths are
never deleted as rollback. A post-publication cleanup/close error can still report
failure with a delivered output, as before. No power-loss durability or universal
filesystem support is added.

Concurrent file mutation is outside a consistent-snapshot guarantee: opened
handles avoid repeatedly resolving inputs, and short reads fail, but contents can
change between reads where the platform permits writers. With a manifest, the
verified copies provide a stable byte source after the initial read.

## Narrow validation record

2026-11-15, Windows x86_64/MSVC Build Tools 2022 and WSL Ubuntu 24.04 x86_64,
release CLI, fixed moon 0.1.20261102 (ea07287 2026-11-02),
moonc v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102. No SDK/dependency
upgrade. New tests are `scripts/test_cli_stream.py`,
`scripts/stream_wbtest.mbt.in`, `internal/bzip2/stream_wbtest.mbt` and the one pure
header-prefix regression. Commands:

```sh
python scripts/test_cli_stream.py --exe _build/bin/linux/moonbsdiff
python scripts/native_test.py stream
moon test internal/bzip2 --filter 'stream pull*' --target native --deny-warn
moon test format_prefix_test.mbt format_wbtest.mbt --target native --deny-warn
```

The Python set has five groups on each platform (42 invocations in its final
definition). Local complete runs passed 41 invocations per platform; the final
short-control assertion and stricter limit diagnostics were then validated by
rerunning only their two affected groups on each platform. Final full-set evidence
is produced by CI. Two independently constructed cases restore 16384 and 131072 bytes, each
using 184 triples, including zero-output seeks and negative/partial old overlap.
Python Random v3/randbytes with seed 20261115026 + target size supplies residuals
and extra bytes; expected target comes from the independent byte/control recipe,
not memory apply. Memory apply is an additional byte-for-byte comparison. Raw
expanded totals are 20800 / 135488 bytes; patches 17471 / 132935 bytes. A separate
131072-byte repeat target exercises paused final RLE expansion. Identities:

| Target bytes | New SHA-256 | Patch SHA-256 |
| --- | --- | --- |
| 16384 | 954eff91e3367b9cf3264d29e46fd9e90ace8fdc3ad4766df6d5002dd53c7bcb | b39a85ef5a81b4f0eb0eb1daf0dec52082b88ca6983937cc560f215bbde384a4 |
| 131072 | ced896e131e2fbfc9b67c7a34be3f224d5937e82d8afef111f199491428c7b35 | 3843730ba1bf459149d21e3c4b3e112af565f651de8f6b54a4cba93e85cf7922 |

Old size 5120, SHA-256 4345361085c730756d843f13849c50a996fe2f1fac3a7ac05fb063bb743a423e.
Hash identity for compressed bytes is scoped to the recorded Python/libbz2
producer; future producers need not make byte-identical compressed streams to
restore the same independent expected target.

The groups also check block/stream CRC corruption in all three intervals,
truncation, garbage, concatenation, empty-stream tail, redundant decoded data,
extreme and overflowing cursors, exact/one-short effective caps, failure/recovery,
input preservation, existing output and incompatible arguments. Private delivery
checks cover interrupted/short/zero-progress writes, writer-close and publication
failure, competing final target, cleanup and a fresh call. Linux additionally
forces the existing guarded compatibility delivery through the same callback.
Source-refill tests use 1/7/4096-byte compressed chunks and 31-byte output pulls,
including within-run pauses and budget-before-expansion assertions.

Directly affected memory compression compact regressions and the new pull test
run on native/JS/Wasm-GC; file CLI tests are Windows/Linux only. No claim of JS or
Wasm file IO is made. Existing historical matrices, oracle, full CLI/IO suites,
large compression probes, resource measurements and benchmarks were not rerun
locally. CI adds the small new paths to existing jobs; the final source SHA and
actual remote run identity belong in the completion report, not a self-referential
source commit. These are historical Commit 26 results; file-only Commit 27
behavior and its separate evidence follow. No release is made.

## Progress and cooperative cancellation (Commit 27)

This addition covers only native file application, not generators, memory apply,
manifest verification or JS asynchronous execution:

```sh
./_build/bin/linux/moonbsdiff patch --stream --progress text OLD PATCH OUTPUT
./_build/bin/linux/moonbsdiff patch --stream --progress json OLD PATCH OUTPUT
```

`--progress` accepts exactly `text` or `json`, once, before paths. It requires
`patch --stream` and follows the existing `--` rule. Show-limits is a separate
invocation. Without it, successful operations stay silent.
Runtime progress, cancellation and error diagnostics go to stderr, never stdout.
Argument/configuration errors exit 2 before an event stream starts and retain
plain text diagnostics. Runtime failure is 1, confirmed cooperative cancellation
before commit is 130, and success is 0.

### Event schema 1

JSON mode emits exactly one JSON object per stderr line; no ordinary product
text is interleaved. Each object contains:

| Field | Meaning |
| --- | --- |
| schema_version | Number 1 |
| event | start, phase, progress, complete, cancelled or error |
| stage | opening, preparing, restoring, validating, delivering or complete |
| restored_bytes | Decimal string: bytes in completed bounded temporary writes |
| total_bytes | Declared target as decimal string after header check; null before it is known |
| output_committed | Boolean: this operation actually published its output |
| message | Standard JSON-escaped diagnostic/information string; may be empty |

This byte count is not an overall-work percentage. CRC/end/complete consumption,
input/writer close, commit admission and delivery can still fail at the full byte
count. A partial failed OS write is not counted as a completed chunk. No ETA is
invented, and empty targets have no division or percentage. Progress is emitted
at phase changes and after another 65536 completed bytes (also at a nonempty
output's final byte count), not per byte or per compression symbol.

For the 8192-byte repeat fixture, actual JSON events include:

```jsonl
{"schema_version":1,"event":"start","stage":"opening","restored_bytes":"0","total_bytes":null,"output_committed":false,"message":"Byte progress is not overall operation completion"}
{"schema_version":1,"event":"progress","stage":"restoring","restored_bytes":"8192","total_bytes":"8192","output_committed":false,"message":"Temporary bytes; final validation/delivery still pending"}
{"schema_version":1,"event":"phase","stage":"validating","restored_bytes":"8192","total_bytes":"8192","output_committed":false,"message":""}
{"schema_version":1,"event":"phase","stage":"delivering","restored_bytes":"8192","total_bytes":"8192","output_committed":false,"message":""}
{"schema_version":1,"event":"complete","stage":"complete","restored_bytes":"8192","total_bytes":"8192","output_committed":true,"message":"All checks and delivery completed"}
```

The restoring phase event between start and progress is omitted above only to
keep this excerpt short. Text mode uses the same state, for example:

```text
moonbsdiff: progress stage=restoring restored_bytes=8192 total_bytes=8192 output_committed=false Temporary bytes; final validation/delivery still pending
moonbsdiff: complete stage=complete restored_bytes=8192 total_bytes=8192 output_committed=true All checks and delivery completed
```

### Notification, checkpoints and irreversible boundary

Each operation owns its progress, session ticket, confirmation and result. The
native routing slot is process-local because this CLI is synchronous; generation
tags prevent an in-flight Windows callback that read an older ticket from
writing into a newer session. A notification delivered during a new session
applies to that current operation. No root API,
public callback framework, worker, background task or object-level concurrent
execution contract is added. Every operation installs its own notification handler
and restores/removes it on the normal cleanup path.

Linux handles SIGINT via sigaction and only assigns sig_atomic_t notification
state in the handler. Windows handles CTRL_C_EVENT and CTRL_BREAK_EVENT with an
Interlocked notification; the OS invokes the handler on its control-handler
thread, and the application creates no background worker. No handler prints,
allocates runtime objects, closes files or removes paths. Ctrl+C must be enabled
by the console environment; Ctrl+Break is the other supported Windows control
notification. SIGTERM/SIGKILL, console close/logoff/shutdown, forced termination
and arbitrary host termination are outside this cooperative cleanup contract.

Normal execution confirms requests before control advancement, bounded decoder
pulls, old reads, output writes, after completed output chunks, at final stream
checks, and immediately before irreversible delivery. The compressed source never
returns empty because of cancellation: it stays a real interval source. A pull
may finish one Huffman/BWT block before the next cancellation check. The shared
decoder/CRC implementation is unchanged; there is no immediate-block interrupt,
strict wall-clock guarantee or budget refund.

The final gate runs after validation and writer closing. Windows uses atomic
compare/exchange for admission; Linux blocks SIGINT, checks both the notification
and pending kernel signals, seals the operation, and restores the signal mask.
Requests observed before admission cancel; after admission the handler continues
to consume the supported notification while the operation reports actual
publication or error. That interval is not cancellable and has no rollback.
`complete` appears only after successful publication, cleanup and handler release.
A post-publication error is `error` with output_committed true; never "cancelled
without output". A competing target may exist with output_committed false:
this field describes only the current operation's publication.

Pre-admission cancellation returns no partial successful result and follows the
existing owned-temporary cleanup. Closing/cleanup/identity warnings remain in the
terminal diagnostic, including when exit is 130; uncertain objects are retained
under existing ownership rules. No success claim hides a cleanup warning and no
caller final path is deleted as rollback. A new call has fresh quotas/session
state even after a previous cancellation or failure.

Native interface references:
[sigaction](https://man7.org/linux/man-pages/man2/sigaction.2.html),
[signal-safety](https://man7.org/linux/man-pages/man7/signal-safety.7.html),
[sigpending](https://man7.org/linux/man-pages/man2/sigpending.2.html),
[SetConsoleCtrlHandler](https://learn.microsoft.com/windows/console/setconsolectrlhandler),
[console process groups](https://learn.microsoft.com/en-us/windows/console/console-process-groups).

### Narrow validation, 2026-11-15

Pinned native release toolchain remains moon 0.1.20261102 (ea07287 2026-11-02),
moonc v0.10.19+bee578715 (2026-11-02), moonrun 0.1.20261102. Windows x86_64 uses
MSVC Build Tools 2022; Linux x86_64 uses WSL Ubuntu 24.04 locally. No dependency,
root interface, default policy or copied decoder change is part of Commit 27.

```sh
python scripts/test_cli_progress.py --exe _build/bin/linux/moonbsdiff
# Windows, from the configured compiler environment:
# python scripts/test_cli_progress.py --exe _build/bin/windows/moonbsdiff.exe
```

The new script runs four normal protocol groups (text/default, JSON/empty,
structured runtime errors, strict parameters) against the production executable.
Only for private cancellation testing it builds a fresh byte-preserving snapshot
of production sources, renames the main function and appends a private wrapper.
That wrapper alone enables checkpoint injection or waiting; no product CLI option
or environment variable enables either. Source hashes, build log and result
records are kept in a fresh ignored _build/p27-* directory.

Private cases: cancel after the first 4096-byte write; cancel plus injected writer
close warning; cancel immediately before commit with a competing output; a late
request followed by actual success; and a late request followed by no-replace
failure. Linux also raises a real SIGINT while it is blocked at admission to
check pending-signal rejection. Each case checks events/result/publication, input
bytes, temporary objects, competing-file preservation and a new successful call
in the same process. Five Windows and six Linux private cases are distinct from
the four normal protocol groups.

Additionally, a private waiting checkpoint enables one controlled external OS
notification per platform: SIGINT sent only to the Linux child PID, and
CTRL_BREAK_EVENT sent only to a Windows child in its own hidden console/group.
The Windows sender is a separate helper process; it detaches only its own
inherited console before attaching to the child, leaving the coordinator and
unrelated processes untouched. Both actual notification paths confirmed exit
status 130 for the operation after 4096 of 8192 temporary bytes, no publication,
zero retained temporary objects and correct subsequent same-process recovery.
These are actual OS notifications, separately recorded from direct handler
injection; Windows keyboard Ctrl+C itself was not automated.

Local checks ran the new groups and targeted follow-ups only. No old stream/CLI/IO
full collection, library target matrix, reference matrix or resource measurement
was rerun locally. CI reuses its existing platform jobs with only this compact new
script added, and retains the existing historical-scale measurement condition.
This implements only the file-application portion of Commit 27 and remains 0.4.0
Unreleased; generator progress/cancellation, JS asynchronous execution and any
new release are outside scope.

## Streaming with a manifest (Unreleased)

```text
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin
moonbsdiff patch --stream --manifest update.json --public-key publisher.pub --signature update.sig old.bin update.patch restored.bin
```

Use a schema-1 manifest from a trusted channel, or pair `--public-key KEY_FILE`
and `--signature SIG_FILE` to verify a detached Ed25519 signature over the exact
manifest bytes in memory before opening old/patch inputs, creating private
copies, or creating temporary/output files. Both signature flags must appear
together. Without signature verification, SHA-256 checks content identity only;
see [detached manifest signing](manifest.md#detached-ed25519-manifest-signing-and-verification-unreleased).

The CLI checks the manifest's declared sizes against the configured limits before
copying. It writes each input to a private temporary file in chunks of at most
4096 bytes and hashes those same chunks. It checks the size, end of input and
SHA-256, then uses only the verified handles for old-file seeks and compressed
patch reads. Changes to the original paths after verification cannot change the
bytes used for recovery. A change during copying can cause a read, length or
hash error. This operation does not provide an atomic filesystem snapshot.

Reserve temporary space for the old-file and patch copies plus the staged
restored file. Windows uses the process temporary directory with exclusive
creation, denied sharing and deletion on close. Linux uses a protected or sticky
local `/tmp` directory and unlinks each exclusive mode-0600 file before writing
content. macOS opens `/private/tmp` (`O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`,
falling back to `$TMPDIR` if `/private/tmp` cannot be opened), verifies
protected/sticky directory permissions, and unlinks each exclusive mode-0600
file before writing content. The restored file uses the existing staging
location and no-replace delivery. The platform and ownership limits of that
delivery still apply.

Progress text and JSON events show the preparing phase with zero restored bytes.
The output hash counts the bytes of successful writes in order. Delivery requires
the expected size, output SHA-256, all stream checks and required closes to pass.
A mismatch can therefore fail after all restored bytes have been written to
temporary storage. That output is discarded and any existing target is preserved.
Cancellation while preparing the inputs uses exit 130 and closes the copies.
The existing commit boundary still governs late cancellation for patch.

## Streaming verification (Unreleased)

```sh
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff verify --stream --manifest update.json --public-key publisher.pub --signature update.sig old.bin update.patch
```

Use this to check recoverability against a schema-1 manifest without saving
restored bytes. Pass `--public-key` and `--signature` together to require a
valid detached Ed25519 signature before opening the old or patch files.
Streaming verification requires a CLI built with the new verify path, which is
absent from the public v0.4.0 archives. The command takes exactly two operands
and requires the manifest. Choose ordinary verify to run the check in memory,
or patch --stream --manifest when you need a restored file delivered.

The private old-file and patch copies use temporary disk space up to their
combined lengths. Recovery uses the existing bounded bzip2 block workspaces
and input/output chunks of at most 4096 bytes. The verifier hashes and releases
each restored chunk. It creates no temporary or final file for the restored
content and holds no full restored buffer. The output byte limit still caps
the total bytes restored and hashed. The verified copies bind the consumed
bytes to the manifest, even if original paths change after copying.

All three compressed streams are checked for CRC, real end and full consumption,
including for empty targets. Size and SHA-256 must match the target in the
manifest. After closing the verified input copies, the verifier checks
cancellation one final time and restores the interrupt handler before printing
the usual verify success line. There is no file commit phase. Prepare and
restore checkpoints still apply; a confirmed cancellation exits 130. Runtime
failure exits 1 and parameter rejection exits 2. These outcomes emit no
success line. The verify command has no progress mode.
