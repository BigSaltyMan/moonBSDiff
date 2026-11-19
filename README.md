# MoonBSDiff

MoonBSDiff is a MoonBit library and command-line tool for binary updates. It
creates and applies BSDIFF40 patches compatible with BSDiff 4.3. Given trusted
SHA-256 manifests, it can choose an update route, verify each step, and write
the restored file.

| Use case | Entry point |
| --- | --- |
| Generate, inspect, or apply a patch in MoonBit | [`BigSaltyMan/moonbsdiff`](pkg.generated.mbti) on native, JavaScript, and Wasm-GC |
| Verify content or plan an update in MoonBit | [`BigSaltyMan/moonbsdiff/manifest`](manifest/pkg.generated.mbti) |
| Work with files and patch chains | `moonbsdiff` CLI for Windows and Linux x86-64 |

## CLI quick start

Download the archive for your platform and verify its SHA-256 before extracting.
Run the executable by its path, or add it to your `PATH`. The
[installation guide](docs/cli-install.md) includes checksum commands and runtime
requirements. [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases)

```sh
# Make a patch and a SHA-256 manifest from two versions.
moonbsdiff diff --manifest update.json old.bin new.bin update.patch

# Inspect the compressed streams and control instructions.
moonbsdiff inspect --deep update.patch

# Verify the patch, then apply it to a new output path.
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin
```

`patch` takes `OLD PATCH OUTPUT`. Choose an output path that does not already
exist. From 0.5.1, use `moonbsdiff manifest plan --help` or `moonbsdiff diff -h`
for command-specific flags and argument order. See the [CLI reference](docs/cli.md),
[manifest format](docs/manifest.md), and [streaming file behavior](docs/file-apply.md).

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

`diff` and `apply` return a `Result` with a structured `BsdiffError`. See the
[memory application guide](docs/apply.md) for error and limit details and the
[manifest guide](docs/manifest.md) to check file identities, choose between a
full-file download and a patch route, or verify a route before delivery.

## 快速验收

这个演示用同一组文件比较三种更新方案。最多一跳时下载 **2048 字节**完整文件，
最多两跳时下载 **368 字节**补丁，两份补丁已在本地时下载 **0 字节**。
最后实际执行离线补丁链，写出 `restored.bin` 并与独立目标逐字节比较。

在仓库根目录用 Python 3.10+ 运行，`--cli` 指向适用的 Windows 或 Linux
可执行文件。v0.5.0 及后续版本可运行这项演示。

```sh
# Windows
python scripts/run_update_demo.py --cli _build/bin/windows/moonbsdiff.exe

# Linux
python scripts/run_update_demo.py --cli _build/bin/linux/moonbsdiff
```

用解包后的发行版时，将 `--cli` 换成实际路径。看到 `UPDATE DEMO PASS` 后，
可以到打印的目录查看恢复文件。[演示步骤、预期 SHA-256 和样本来源](docs/update-demo.md)

## Build and test

Source builds use `moon 0.1.20261102`, `moonc v0.10.19+bee578715`, Python 3.10+
and a native C compiler. On Windows, run from an initialized MSVC developer
shell.

```sh
moon update
python scripts/build_cli.py --release
moon run cmd/example --target js
moon test --target native --deny-warn
```

The build script writes the CLI to `_build/bin/windows/moonbsdiff.exe` or
`_build/bin/linux/moonbsdiff`. See [source checks and BSDiff interoperability](docs/compatibility.md)
and [CI results](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml).

## Limits and trust

- Default generation accepts old and new buffers up to **64 KiB** and caps
  patches at **128 KiB**. From 0.5.1, default library application accepts the
  same patch size. Application limits also cap output and total decompression.
  Other work limits can reject an input even when its file sizes fit.
  [Generation policy and measured 256 KiB and 1 MiB examples](docs/generation-scales.md)
- BSDIFF40 has no built-in file identity check. Use a manifest from a trusted
  source when verifying input and output identities. File hashes establish
  content identity. Publisher authentication requires a separate trust mechanism.
- The CLI does not overwrite existing files. Streaming verification and
  delivery can use private temporary files. Linux delivery depends on the
  output filesystem and directory permissions.
  [Delivery and cancellation behavior](docs/file-apply.md)

## Project references

- [Changelog](CHANGELOG.md) and [0.5.0 release evidence](docs/release-0.5.0.md)
- [BSDIFF40 format](docs/format.md) and [benchmarks](docs/benchmarks.md)
- [BSD-2-Clause license](LICENSE) and [upstream and third-party notices](docs/upstream.md)
