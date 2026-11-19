# MoonBSDiff 0.5.0 release

## Scope

This release includes the cross-target manifest package, deep patch inspection,
streaming verification and delivery, manifest-bound update planning, and offline
patch-chain recovery. The [quick acceptance demo](update-demo.md) exercises
download choices of 2048, 368 and zero bytes, then compares the delivered target
with an independent file.

- Candidate audit compares each packed file with the clean release export.
- The external library consumer imports `BigSaltyMan/moonbsdiff/manifest`,
  creates a patch bundle, plans an update, and restores the selected candidate.
- The two CLI archives are tied to the CI checkout SHA. The ordinary CLI job
  runs the demo from the build directory. The publication check runs it with
  the executable extracted from the public archive.

## Release entry points

- [Mooncakes 0.5.0 metadata](https://mooncakes.io/api/v0/manifest/BigSaltyMan/moonbsdiff/0.5.0)
  reports the actual returned version and package checksum.
- [GitHub v0.5.0 Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.5.0)
  provides the Windows and Linux x86_64 archives and checksums.
- [Installation](cli-install.md), [manifest policy](manifest.md),
  [compatibility](compatibility.md) and [licenses](upstream.md) describe the
  verification, runtime and platform boundaries. Previous releases keep their
  own source and asset records.

The links above name the release targets. Exact public identities and fresh
registry and CLI results are recorded separately after publication.
