# MoonBSDiff

MoonBSDiff is a MoonBit library and command-line tool for binary updates. It
creates and applies BSDIFF40 patches compatible with BSDiff 4.3. Given trusted
SHA-256 manifests (optionally authenticated with detached Ed25519 signatures),
it can choose an update route, verify each step, and write the restored file.

| Use case | Entry point |
| --- | --- |
| Generate, inspect, or stream-apply a patch in MoonBit | [`BigSaltyMan/moonbsdiff`](pkg.generated.mbti) on native, JavaScript, and Wasm-GC |
| Verify, sign, or plan updates in MoonBit | [`BigSaltyMan/moonbsdiff/manifest`](manifest/pkg.generated.mbti) |
| Work with files and patch chains | `moonbsdiff` CLI for Windows (`x86_64`), Linux (`x86_64`, `arm64`), and macOS (`arm64`) |

## CLI quick start

Download the archive for your platform and verify its SHA-256 before extracting.
Published `0.5.4` archives cover Windows and Linux `x86_64`; macOS `arm64` and
Linux `arm64` targets are available in unreleased source builds and packaging. Run the
executable by its path, or add it to your `PATH`. The
[installation guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md) includes checksum commands and runtime
requirements. [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases)

```sh
# Make a patch and a SHA-256 manifest from two versions.
moonbsdiff diff --manifest update.json old.bin new.bin update.patch

# Inspect the compressed streams and control instructions.
moonbsdiff inspect --deep update.patch

# Verify the patch, then apply it to a new output path.
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin

# Optional (unreleased): sign a manifest and require publisher authentication.
moonbsdiff manifest keygen publisher.key publisher.pub
moonbsdiff manifest sign --private-key publisher.key update.json update.sig
moonbsdiff manifest verify-sig --public-key publisher.pub --signature update.sig update.json
moonbsdiff patch --stream --manifest update.json --public-key publisher.pub --signature update.sig old.bin update.patch verified.bin
```

`patch` takes `OLD PATCH OUTPUT`. Choose an output path that does not already
exist. From 0.5.1, use `moonbsdiff manifest plan --help` or `moonbsdiff diff -h`
for command-specific flags and argument order. See the [CLI reference](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md),
[manifest format](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md), and [streaming file behavior](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md).

## MoonBit library

From your MoonBit project, add the library. Append `@VERSION` to select a
specific registry version.

```sh
moon add BigSaltyMan/moonbsdiff
```

Import the library from your `moon.pkg`.

```moonbit
import {
  "BigSaltyMan/moonbsdiff",
}
```

```moonbit
fn main {
  let old = b"MoonBSDiff\x00version 1\xff"
  let expected = b"MoonBSDiff\x00version 2!\xff"
  let patch = @moonbsdiff.diff(old, expected, @moonbsdiff.Limits::for_diff()).unwrap()
  let restored = @moonbsdiff.apply(old, patch, @moonbsdiff.Limits::for_apply()).unwrap()
  if restored != expected {
    abort("restored bytes differ from the expected version")
  }
}
```

`diff` and `apply` return a `Result` with a structured `BsdiffError`; standalone
`diff` automatically trims shared leading/trailing byte runs (`>= 64` bytes) for
speed—skipping suffix-array sorting on identical, pure-insert, and pure-delete
updates and sorting only the differing middle (trading away matches that copy
prefix/suffix blocks into a differing middle)—while `DiffIndex::diff` keeps
full-SA matching for all inserts and edits and applies the zero-search fast path
only for identical and pure-deletion pairs, with both emitting standard BSDIFF40
output. For chunked callback-based streaming
application on native, JavaScript, and Wasm-GC, use `apply_stream` (`<= 4096`-byte
chunks). See the [application guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md) for in-memory and streaming details, and the
[manifest guide](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md) to verify detached Ed25519 manifest signatures, check file
identities, choose between a full-file download and a patch route, or verify a
route before delivery.

## 快速验收

这个演示用同一组文件比较三种更新方案。最多一跳时下载 **2048 字节**完整文件，
最多两跳时下载 **359 字节**补丁，两份补丁已在本地时下载 **0 字节**。
最后实际执行离线补丁链，写出 `restored.bin` 并与独立目标逐字节比较。

在仓库根目录用 Python 3.10+ 运行该演示脚本（CLI `unittest` 测试套件需 Python
3.11+），`--cli` 指向适用的 Windows、Linux 或 macOS (`arm64`) 可执行文件。
当前源码树的 `scripts/run_update_demo.py` 校验引入公共前后缀快路径后的
`155` 字节 `v2-to-v3.patch` / `359` 字节总补丁路线；已发布的 `v0.5.0`–`v0.5.4`
二进制早于该快路径，会生成 `164` 字节 `v2-to-v3.patch`（共 `368` 字节），验证
这些旧版本时请使用对应 tag 下的 `scripts/run_update_demo.py`。

```sh
# Windows
python scripts/run_update_demo.py --cli _build/bin/windows/moonbsdiff.exe

# Linux
python scripts/run_update_demo.py --cli _build/bin/linux/moonbsdiff

# macOS (unreleased source build)
python scripts/run_update_demo.py --cli _build/bin/macos/moonbsdiff
```

用解包后的发行版时，将 `--cli` 换成实际路径。看到 `UPDATE DEMO PASS` 后，
可以到打印的目录查看恢复文件。[演示步骤、预期 SHA-256 和样本来源](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/update-demo.md)

## Build and test

Source builds use `moon 0.1.20261102`, `moonc v0.10.19+bee578715`, Python 3.10+
for build/packaging/demo scripts (Python 3.11+ for the CLI `unittest` test suite,
which uses `contextlib.chdir`), and a native C compiler. On Windows, run from an
initialized MSVC developer shell.

```sh
moon update
python scripts/build_cli.py --release
moon run cmd/example --target js
moon test --target native --deny-warn
```

The build script writes the CLI to `_build/bin/windows/moonbsdiff.exe`,
`_build/bin/linux/moonbsdiff`, or `_build/bin/macos/moonbsdiff`. Release
packaging covers 4 CI-built targets (`windows-x86_64`, `linux-x86_64`,
`linux-arm64`, `macos-arm64`; 6 assets including `SHA256SUMS` and
`build-info.json`; macOS `arm64` and Linux `arm64` are unreleased). Intel macOS
(`macos-x86_64`) is not built in CI because upstream MoonBit `0.10.19` does not
publish `darwin-x86_64` native toolchains. See
[source checks and BSDiff interoperability](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md)
and [CI results](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml).

## Limits and trust

- Default generation accepts old and new buffers up to **64 KiB** and caps
  patches at **128 KiB**. From 0.5.1, default library application accepts the
  same patch size. Application limits also cap output and total decompression.
  Other work limits can reject an input even when its file sizes fit.
  [Generation policy and measured 256 KiB and 1 MiB examples](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md)
- BSDIFF40 has no built-in file identity check. Unsigned Schema 1 manifests
  verify content identity (SHA-256) only. Publisher authentication requires
  pinning the publisher's trusted Ed25519 `PUBLIC_KEY_FILE` (or `PublicKey`)
  out-of-band and verifying a detached signature (`--public-key` +
  `--signature`, `manifest verify-sig`, or `prepare_signed`/`apply_signed`).
- The CLI does not overwrite existing files. Streaming verification and
  delivery use private temporary objects. POSIX delivery on Linux and macOS
  depends on the output filesystem and protected parent directory permissions.
  [Delivery and cancellation behavior](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md)

## Project references

- [Changelog](CHANGELOG.md) and [0.5.4 release evidence](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/release-0.5.4.md)
- [BSDIFF40 format](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/format.md) and [benchmarks](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/benchmarks.md)
- [BSD-2-Clause license](LICENSE) and [upstream and third-party notices](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/upstream.md)
