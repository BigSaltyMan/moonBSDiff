# MoonBSDiff

> [English](https://github.com/BigSaltyMan/moonBSDiff/blob/master/README.md) | **简体中文**

MoonBSDiff 是一个用于二进制增量更新的 MoonBit 库与原生命令行工具。
它生成并应用与 BSDiff 4.3 兼容的 **BSDIFF40** 补丁，内置资源边界控制、跨目标流式应用、SHA-256 更新清单（manifest），以及可选的独立 **Ed25519** 发布者签名校验。

## 核心特性

- **标准 BSDIFF40 兼容** — 与上游 BSDiff 4.3 双向互操作，库同时支持 Native、JavaScript 与 Wasm-GC 目标。
- **前后缀快路径与流式应用** — 独立 `diff` 自动裁剪长度 `>= 64` 字节的公共前后缀以提速；提供跨目标 `apply_stream`，按有界 `<= 4096` 字节分块流式还原。
- **可校验与可签名更新** — 配合 Schema 1 SHA-256 清单进行多跳路线规划与内容一致性校验，并可通过独立 Ed25519 签名验证发布者身份。
- **默认有界且安全交付** — 库默认限制内存、解压总量与计算步数；CLI 绝不覆盖已有文件，并通过私有临时对象安全落盘。
- **多平台原生 CLI** — 支持 Windows（`x86_64`）、Linux（`x86_64`、`arm64`）与 macOS（`arm64`）。

## 入口一览

| 使用场景 | 入口 |
| --- | --- |
| 在 MoonBit 中生成、检查或流式应用补丁 | [`BigSaltyMan/moonbsdiff`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/pkg.generated.mbti)（`native`、`js`、`wasm-gc`） |
| 在 MoonBit 中校验、签名或规划更新路线 | [`BigSaltyMan/moonbsdiff/manifest`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/manifest/pkg.generated.mbti)（`native`、`js`、`wasm-gc`） |
| 直接处理本地文件、签名与补丁链 | `moonbsdiff` CLI — Windows（`x86_64`）、Linux（`x86_64`、`arm64`）、macOS（`arm64`） |

---

## CLI 快速开始

前往 [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases) 下载对应平台的预编译压缩包，先校验 SHA-256，再解压使用。
自 `0.6.0` 起，发行包覆盖 Windows（`x86_64`）、Linux（`x86_64`、`arm64`）和 macOS（`arm64`）；早期 `0.5.x` 发行包覆盖 Windows 与 Linux（`x86_64`）。
校验命令与运行时要求请见 [CLI 安装指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md)。

### 基础流程

```sh
# 1. 根据旧、新文件生成 BSDIFF40 补丁和 SHA-256 清单
moonbsdiff diff --manifest update.json old.bin new.bin update.patch

# 2. 检查压缩流与控制指令结构
moonbsdiff inspect --deep update.patch

# 3. 先流式校验补丁，再应用到新的输出路径
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin
```

### 可选：Ed25519 发布者签名

```sh
# 生成发布者密钥对（私钥以仅所有者可读写权限安全落盘）
moonbsdiff manifest keygen publisher.key publisher.pub

# 对清单生成独立签名文件，并可单独验证
moonbsdiff manifest sign --private-key publisher.key update.json update.sig
moonbsdiff manifest verify-sig --public-key publisher.pub --signature update.sig update.json

# 在打开输入文件或写出结果前强制验证发布者签名
moonbsdiff patch --stream \
  --manifest update.json \
  --public-key publisher.pub \
  --signature update.sig \
  old.bin update.patch verified.bin
```

> **提示**
> - `patch` 的位置参数顺序为 `OLD PATCH OUTPUT`，且 `OUTPUT` 必须尚不存在。
> - 可运行 `moonbsdiff <子命令> --help`（如 `moonbsdiff manifest plan --help` 或 `moonbsdiff diff -h`）查看具体参数与顺序。
> - 详细说明见 [CLI 参考手册](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md)、[清单与签名指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md) 和 [流式文件交付行为](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md)。

---

## MoonBit 库用法

在你的 MoonBit 项目中添加依赖（如需锁定版本，可在末尾附加 `@VERSION`）：

```sh
moon add BigSaltyMan/moonbsdiff
```

在 `moon.pkg` 中引入包：

```moonbit
import {
  "BigSaltyMan/moonbsdiff",
}
```

### 最小内存示例

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

### 核心 API 与行为说明

- **结构化错误与资源上限** — `diff` 与 `apply` 返回 `Result[Bytes, BsdiffError]`，包含明确的错误类型、阶段和限额信息（默认配置见 `Limits::for_diff()`、`Limits::for_apply()`）。
- **快路径 `diff` 与 `DiffIndex::diff`** — 独立 `diff` 会自动裁剪长度 `>= 64` 字节的公共前后缀：对完全相同、纯插入、纯删除输入直接跳过后缀数组排序，一般修改仅对中间差异区间建索引（以放弃从前后缀复制到中间差异区的匹配来换取速度）；而 `DiffIndex::diff` 对所有插入与修改均保留完整后缀数组匹配，仅对完全相同或纯删除输入启用零搜索快路径。两者均输出标准 BSDIFF40 补丁。
- **跨目标流式应用（`apply_stream`）** — 通过区间读取回调（`read_old_at`、`read_patch_at`）与分块写出回调（`write_output`，单块 `<= 4096` 字节），在 Native、JS 和 Wasm-GC 上完成流式还原。详见 [应用指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md)。
- **清单、路线规划与 Ed25519 签名** — 引入 `BigSaltyMan/moonbsdiff/manifest` 可完成 SHA-256 内容身份校验、全量下载与补丁链对比决策（`plan_update`），以及基于独立 Ed25519 签名的清单认证（`prepare_signed`、`apply_signed`、`verify_manifest_signature`）。详见 [清单与签名指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md)。

---

## 端到端快速验收

验收脚本使用同一组样本文件比较三种更新策略，最后实际执行离线补丁链写出 `restored.bin`，并与独立目标文件逐字节核对：

| 策略条件 | 选中方案 | 下载体积 |
| --- | --- | --- |
| 最多 1 跳 | 下载完整目标文件 | **2048 字节** |
| 最多 2 跳 | 两跳补丁链（`v1 -> v2 -> v3`） | **359 字节** |
| 两份补丁已在本地 | 离线执行本地补丁链 | **0 字节** |

在仓库根目录使用 Python 3.10+ 运行（CLI `unittest` 测试套件需 Python 3.11+），将 `--cli` 指向对应平台的可执行文件：

```sh
# Windows (x86_64)
python scripts/run_update_demo.py --cli _build/bin/windows/moonbsdiff.exe

# Linux (x86_64 或 arm64)
python scripts/run_update_demo.py --cli _build/bin/linux/moonbsdiff

# macOS (arm64)
python scripts/run_update_demo.py --cli _build/bin/macos/moonbsdiff
```

若使用解压后的预编译发行版，请将 `--cli` 替换为实际可执行文件路径。看到 `UPDATE DEMO PASS` 后，可在终端打印的目录中查看已校验的还原文件。

> **版本差异说明：** `0.6.0` 及以上版本启用公共前后缀快路径，生成 `155` 字节 `v2-to-v3.patch`（总补丁路线 `359` 字节）；已发布的 `v0.5.0`–`v0.5.4` 二进制早于该优化，生成 `164` 字节（总计 `368` 字节），验证旧版本请使用对应 git tag 下的 `scripts/run_update_demo.py`。
> 详见 [演示步骤、预期 SHA-256 与样本来源](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/update-demo.md)。

---

## 从源码构建与测试

### 环境要求

- **MoonBit 工具链**：`moon 0.1.20261102`、`moonc v0.10.19+bee578715`
- **Python**：构建、打包与演示脚本需 `3.10+`（CLI `unittest` 测试套件因使用 `contextlib.chdir` 需 `3.11+`）
- **C 编译器**：原生 C 工具链（Windows 下请在已初始化的 MSVC 开发者终端中运行）

### 构建与验证

```sh
moon update
python scripts/build_cli.py --release
moon run cmd/example --target js
moon test --target native --deny-warn
```

构建脚本会输出原生可执行文件到 `_build/bin/windows/moonbsdiff.exe`、`_build/bin/linux/moonbsdiff` 或 `_build/bin/macos/moonbsdiff`。

发行打包覆盖 **4 个 CI 原生目标**（`windows-x86_64`、`linux-x86_64`、`linux-arm64`、`macos-arm64`），共产出 **6 个发布产物**（4 份归档 + `SHA256SUMS` + `build-info.json`）。由于上游 MoonBit `0.10.19` 未提供 `darwin-x86_64` 原生工具链，CI 不构建 Intel macOS（`macos-x86_64`）。

详见 [兼容性与 BSDiff 互操作说明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) 与 [CI 运行记录](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml)。

---

## 资源限制与安全边界

- **资源上限** — 默认补丁生成接受最大 **64 KiB** 的旧/新输入并将补丁上限设为 **128 KiB**；默认库应用采用相同补丁上限，并同时限制输出大小、总解压字节数与计算开销。详见 [大文件生成策略（256 KiB 与 1 MiB 实测）](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md)。
- **内容完整性 vs. 发布者信任** — BSDIFF40 格式本身不含文件哈希。未签名的 Schema 1 清单仅校验内容身份（SHA-256）。如需验证发布者身份，必须通过带外渠道固定发布者可信 Ed25519 公钥（`PUBLIC_KEY_FILE` 或 `PublicKey`），并校验独立签名（`--public-key` + `--signature`、`manifest verify-sig`，或 `prepare_signed`/`apply_signed`）。
- **无损交付机制** — CLI 绝不覆盖现有文件。流式校验与交付均使用私有临时对象；Linux 与 macOS 上的 POSIX 安全交付依赖目标文件系统能力及受保护的父目录权限。详见 [交付与取消行为说明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md)。

---

## 相关文档与参考

| 分类 | 文档链接 |
| --- | --- |
| **使用指南** | [CLI 安装指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md) · [CLI 参考手册](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md) · [库应用指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md) · [清单与签名指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md) · [流式文件交付](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md) |
| **技术参考** | [BSDIFF40 格式规范](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/format.md) · [大文件生成策略](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md) · [基准测试](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/benchmarks.md) · [兼容性与互操作](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) |
| **项目与发布** | [变更日志 (Changelog)](https://github.com/BigSaltyMan/moonBSDiff/blob/master/CHANGELOG.md) · [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases) · [BSD-2-Clause 许可证](https://github.com/BigSaltyMan/moonBSDiff/blob/master/LICENSE) · [上游与第三方声明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/upstream.md) |
