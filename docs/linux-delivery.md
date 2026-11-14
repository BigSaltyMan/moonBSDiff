# Linux delivery compatibility (CLI 0.2.0)

This changes the native CLI delivery adapter, not BSDIFF40 or the library API.
The published 0.1.0 requirements remain historical facts. Windows delivery is
unchanged. This is not support for all Linux filesystems or power-loss durability.

## Route selection

The preferred route still opens the destination directory, creates an anonymous
`O_TMPFILE` inode, obtains its `/proc/self/fd` reference, writes completely,
checks writer close, and publishes using non-replacing `linkat`.

Before writing, an anonymous-open failure with `EOPNOTSUPP`, `EINVAL`, `EISDIR`,
`ENOSYS`, or `ENOENT` can select compatibility. These are capability failures for
the fixed open arguments and already-open directory, including old-kernel
behavior. A `/proc` keeper-open failure with `ENOENT` or `ENOTDIR` can also select
compatibility, after successfully closing the unused anonymous writer. An
unsuccessful close, permission failure, no-space/quota failure, write failure,
or publication failure does not retry through another route. `/proc` denied with
`EACCES` is deliberately not treated as an absent facility.

Compatibility requires the local ext filesystem type (`0xef53`), genuine Unix
permission semantics, and a protected destination directory. Its owner must be
the effective UID or root. A group/world-writable directory must have the sticky
bit. Other filesystem types fail explicitly in compatibility mode. Only ext4
has been exercised; the shared filesystem identifier is not evidence that every
ext variant, mount configuration, or kernel was tested. Existing primary-route
support on other filesystems is not removed.

## Objects, publication, and cleanup

1. Keep the destination directory descriptor; do not resolve its user path again
   during publication or cleanup.
2. Obtain 128 random bits from `getrandom`, and exclusively create a
   `.moonbsdiff-compat-<hex>` directory with mode 0700. Retry at most 128 name
   collisions. Collision objects are neither opened as payloads nor removed.
3. Verify owner, exact permission bits, and directory identity. Open it with
   `O_DIRECTORY|O_NOFOLLOW`, anchored to the destination directory.
4. Exclusively create `payload` with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600.
   Verify regular-file type, owner, mode, link count, and the identity of an
   `O_PATH` reference. A restrictive umask or unexpected ACL/mode result may
   cause refusal rather than silently relaxing these checks.
5. Loop on short writes and EINTR; reject zero progress. Check writer close
   before publication, without retrying close after EINTR. The retained
   reference is not a writable handle.
6. Recheck namespace identities and call
   `linkat(private_fd, "payload", destination_fd, leaf, 0)`. This hard link
   fails if the destination already exists, including a racing creator.
   There is no ordinary rename, final-path truncation, or check-then-overwrite.
7. Remove only the owned private payload and private directory under the
   permission assumptions below, then close retained descriptors. Never remove
   the final user path as a rollback.

No `AT_EMPTY_PATH` privilege is required. Hard links and the listed creation,
descriptor, permission, and entropy facilities must actually work; otherwise
delivery fails. This route does not promise network/9p/DrvFS/FAT/overlay support.

The security basis is the protected parent plus an owner-only private directory.
Another UID cannot replace the newly created directory during mkdir/open under
these parent rules, or mutate its payload. Ancestor renaming does not redirect
the held directory descriptors. Root and malicious control of processes or
namespaces by the same UID are outside this threat model. Parent/mount control
beyond these assumptions is not covered. Inode comparisons are defense in
depth, **not** an atomic compare-and-unlink primitive or a universal solution to
hostile parent-directory races.

Unexpected identity, permission changes, or failed cleanup produce an error;
uncertain objects are retained rather than deleting a replacement. A diagnostic
names a temporary directory that may have been renamed or replaced: inspect it
before manual cleanup; do not blindly delete that path. A failure after a
successful final hard link explicitly says `output already delivered`, returns
failure, and preserves the output. No fsync/directory-fsync or crash/power-loss
durability guarantee is made.

All operations share this adapter. `diff --manifest` remains two independent
deliveries, not a transaction: a delivered patch is not deleted if manifest
delivery fails. `patch --manifest` still completes identity and restoration
checks before any final output delivery. Existing output/input identity
preflight and no-overwrite behavior remain in place.

## Verification and reproduction

The pinned SDK is moon `0.1.20261102 (ea07287 2026-11-02)`, moonc
`v0.10.19+bee578715 (2026-11-02)`; the CLI was built native debug using
`python3 scripts/build_cli.py`.

The Linux-only private contracts run with:

```sh
moon test cmd/main/linux_compat_wbtest.mbt --target native --deny-warn
```

Two nonempty grouped tests cover 18 scenarios: forced capability fallback,
temporary collision, competing final target, payload/directory replacement,
write/close/link failures and cleanup, permission refusal without retry,
missing-proc selection, capability-transition close failure, short/zero writes,
parent permission policy, primary write/close errors without fallback, and
post-publication cleanup failure without rollback. Hooks exist only through a
private test entrypoint, with no product environment variable or CLI switch.

The real environment check runs separately:

```sh
python3 scripts/test_linux_delivery.py --exe _build/bin/linux/moonbsdiff
```

It requires a local ext filesystem for the system temporary directory and
permission to create a private mount namespace (normally noninteractive sudo).
It mounts an empty tmpfs over `/proc` **only inside that private namespace**,
then drops to an ordinary UID/GID, clears groups/capabilities, and sets
`no_new_privs`. The CLI is not run with elevated capabilities. There are no
product fault hooks. Missing isolation prerequisites fail the check, not skip it.
The host mount namespace is checked before and after. The isolated scratch
directory is intentionally retained in the system temporary directory for
inspection; the test does not perform recursive cleanup under root.

Actual local evidence: Ubuntu 24.04 under WSL2, x86_64,
`6.6.87.2-microsoft-standard-WSL2`, ext4 system temporary directory. UID 1000 had
zero effective/permitted capabilities. `O_TMPFILE` succeeded, but opening the
`/proc/self/fd` reference failed with ENOENT. Official CLI `diff --manifest`,
`patch --manifest`, and `verify --manifest` all succeeded. The fixed 5-byte old
and 6-byte new inputs produced a 153-byte patch and a 405-byte manifest;
restoration matched all bytes and SHA-256, inputs were unchanged, and no
compatibility objects remained. This proves the newly supported missing-proc
scenario. Unsupported-O_TMPFILE selection is additionally covered by private
contracts; a genuinely O_TMPFILE-unsupported filesystem was not exercised.

[The compact evidence record](../testdata/cli/linux-delivery-compat.json) binds
these results to the native adapter and executable hashes. Runtime reports/logs
are written into ignored `_build/`. CI reuses its existing Linux CLI build for
this isolated check; private contracts are part of its existing native tests.
No local historical CLI/IO suite, library matrix, interoperability matrix,
compression probe, or resource measurement was rerun for this change.

## Interface references

Linux documents anonymous-file flags and capability failure behavior in
[open(2)](https://man7.org/linux/man-pages/man2/open.2.html), hard-link creation
and EEXIST/non-replacement in
[link(2)](https://man7.org/linux/man-pages/man2/link.2.html), and ordinary rename's
replacement behavior in
[rename(2)](https://man7.org/linux/man-pages/man2/rename.2.html). The implementation
uses hard-link publication rather than assuming ordinary rename is safe after
a separate existence check.
