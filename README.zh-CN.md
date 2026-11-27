# MoonBSDiff

> [English](https://github.com/BigSaltyMan/moonBSDiff/blob/master/README.md) | **简体中文**

MoonBSDiff 是一个用于可验证二进制增量更新的 MoonBit 库与原生命令行工具。
它基于线性时间 **SA-IS** 后缀数组引擎生成并应用与 BSDiff 4.3 兼容的 **BSDIFF40** 补丁，内置补丁预检取证、有界流式应用、多公钥 **Ed25519** 签名发布目录，以及整目录增量包。

## 核心特性

- **标准 BSDIFF40 与线性时间 `O(n)` SA-IS** — 与上游 BSDiff 4.3 双向互操作，库同时支持 Native、JavaScript 与 Wasm-GC；将线性时间 SA-IS 索引构建、公共前后缀快路径裁剪（`>= 64` 字节）与跨目标流式应用 `apply_stream`（单块 `<= 4096` 字节）结合在一起。
- **补丁预检取证与解压炸弹审计** — 无需旧文件、也不分配还原输出缓冲，即可计算流膨胀比、前 64 条控制样本、确定性风险标记（`HIGH_EXPANSION_RATIO`、`EXCESSIVE_CONTROL_DENSITY` 等）和最小合法 `required_limits`（`analyze_patch` / `inspect --analyze`）。
- **多公钥轮换与签名发布目录** — 支持同时固定多把 Ed25519 公钥（`TrustStore` / 可重复 `--public-key`），提供防重放（`min_catalog_version`）、防降级多跳路线规划（`VerifiedCatalog::plan_update` / `manifest catalog`）与签名补丁链验证（`patch-chain` / `verify-chain`）。
- **整目录增量包** — 对整个目录树执行增量打包、校验与还原（`dir_diff` / `dir_apply_signed` / `dir-diff`、`dir-verify`、`dir-patch`），内置规范 `tree_sha256`、零字节未变更/重命名去重、BSDIFF40 与全量回退自动择优、严格路径与符号链接防护，以及独立 Ed25519 签名。
- **差异化 Web Studio 与多平台原生 CLI** — 零后端纯客户端浏览器工作台（[Web Studio](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md)）直接运行编译后的 MoonBit JS 内核；原生 CLI 覆盖 Windows（`x86_64`）、Linux（`x86_64`、`arm64`）与 macOS（`arm64`）。

## 入口一览

| 使用场景 | 入口 |
| --- | --- |
| 在 MoonBit 中生成、取证分析或流式应用补丁 | [`BigSaltyMan/moonbsdiff`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/pkg.generated.mbti)（`native`、`js`、`wasm-gc`） |
| 在 MoonBit 中校验清单、轮换公钥、规划签名目录或对比目录树 | [`BigSaltyMan/moonbsdiff/manifest`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/manifest/pkg.generated.mbti)（`native`、`js`、`wasm-gc`） |
| 直接处理本地文件、发布目录、签名补丁链与目录增量包 | `moonbsdiff` CLI — Windows（`x86_64`）、Linux（`x86_64`、`arm64`）、macOS（`arm64`） |
| 浏览器内补丁 X 光取证、红队目录演练、流式示波器与目录增量体验 | [MoonBSDiff Web Studio](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md)（`cmd/studio` -> JS ESM） |

---

## CLI 快速开始

前往 [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases) 下载对应平台的预编译压缩包，先校验 SHA-256，再解压使用。
自 `0.6.0` 起，发行包覆盖 Windows（`x86_64`）、Linux（`x86_64`、`arm64`）和 macOS（`arm64`）；早期 `0.5.x` 发行包覆盖 Windows 与 Linux（`x86_64`）。
校验命令与运行时要求请见 [CLI 安装指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md)。

### 单文件基础流程与预检取证

```sh
# 1. 根据旧、新文件生成 BSDIFF40 补丁和 SHA-256 清单
moonbsdiff diff --manifest update.json old.bin new.bin update.patch

# 2. 运行补丁预检取证、风险标记与最小限额推导（也可使用 --deep）
moonbsdiff inspect --analyze --json update.patch

# 3. 先流式校验补丁，再应用到新的输出路径
moonbsdiff verify --stream --manifest update.json old.bin update.patch
moonbsdiff patch --stream --manifest update.json old.bin update.patch restored.bin
```

### Ed25519 签名、密钥轮换与签名发布目录

```sh
# 生成发布者密钥对（私钥以仅所有者可读写权限安全落盘）
moonbsdiff manifest keygen key-v1.key key-v1.pub
moonbsdiff manifest keygen key-v2.key key-v2.pub

# 对清单或发布目录签名，并在双公钥重叠期内完成无缝轮换验证
moonbsdiff manifest sign --private-key key-v1.key update.json update.sig
moonbsdiff patch --stream --manifest update.json \
  --public-key key-v1.pub --public-key key-v2.pub --signature update.sig \
  old.bin update.patch verified.bin

moonbsdiff manifest catalog sign --private-key key-v2.key catalog.json catalog.sig
moonbsdiff manifest catalog plan \
  --public-key key-v1.pub --public-key key-v2.pub --signature catalog.sig \
  --current-version 1 --target-version 3 --min-catalog-version 2 --allow-full --json \
  catalog.json old.bin
```

### 签名整目录增量包

```sh
# 对比 old_dir -> new_dir 生成签名目录增量包（未变更/重命名零字节 + BSDIFF40/自动全量回退）
moonbsdiff dir-diff --private-key key-v2.key old_dir new_dir release_bundle

# 读取输入前先验签、校验整棵目录树哈希，并无损还原到新目录
moonbsdiff dir-verify --public-key key-v1.pub --public-key key-v2.pub \
  --signature release_bundle/dir-manifest.sig old_dir release_bundle
moonbsdiff dir-patch --public-key key-v1.pub --public-key key-v2.pub \
  --signature release_bundle/dir-manifest.sig old_dir release_bundle restored_dir
```

> **提示**
> - `patch` 的位置参数顺序为 `OLD PATCH OUTPUT`，且 `OUTPUT` / `BUNDLE_DIR` / `OUTPUT_DIR` 必须尚不存在。
> - 可运行 `moonbsdiff <子命令> --help`（如 `moonbsdiff manifest catalog plan --help` 或 `moonbsdiff dir-diff -h`）查看具体参数与顺序。
> - 详细说明见 [CLI 参考手册](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md)、[补丁预检取证指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md)、[发布目录与密钥轮换指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/catalog.md)、[目录增量包指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md) 和 [流式文件交付行为](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md)。

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

- **结构化错误与线性时间 SA-IS** — `diff` 与 `apply` 返回 `Result[Bytes, BsdiffError]`，包含明确的错误类型、阶段和限额信息（默认配置见 `Limits::for_diff()`、`Limits::for_apply()`）。后缀数组构建采用线性时间 `O(n)` SA-IS 并持续扣减有界 `SortBudget`（详见 [SA-IS 后缀数组说明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/suffix-array.md)）。
- **快路径 `diff` 与 `DiffIndex::diff`** — 独立 `diff` 会自动裁剪长度 `>= 64` 字节的公共前后缀：对完全相同、纯插入、纯删除输入直接跳过后缀数组排序，一般修改仅对中间差异区间建索引（以放弃从前后缀复制到中间差异区的匹配来换取速度）；而 `DiffIndex::diff` 对所有插入与修改均保留完整后缀数组匹配，仅对完全相同或纯删除输入启用零搜索快路径。两者均输出标准 BSDIFF40 补丁。
- **预检取证（`analyze_patch`）与流式应用（`apply_stream`）** — 使用 `analyze_patch` 审计不可信补丁的膨胀比、风险标记与最小 `required_limits`（详见 [补丁预检取证指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md)），或通过 `apply_stream` 在 Native、JS 和 Wasm-GC 上按 `<= 4096` 字节分块流式还原（详见 [应用指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md)）。
- **清单、多公钥发布目录与目录增量** — 引入 `BigSaltyMan/moonbsdiff/manifest` 可完成独立 Ed25519 清单签名（详见 [清单与签名指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md)）、多公钥 `TrustStore` 轮换、`verify_signed_candidates` 批量预验、防重放/防降级 `ReleaseCatalog` 路由规划（详见 [发布目录指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/catalog.md)），以及 `dir_diff` / `dir_apply_signed` 整目录增量打包与还原（详见 [目录增量包指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md)）。

---

## 端到端快速验收

### 0.7.0 全特性综合验收脚本

使用 [`scripts/run_070_acceptance.py`](https://github.com/BigSaltyMan/moonBSDiff/blob/master/scripts/run_070_acceptance.py) 一键跑通全部 4 项核心能力（补丁预检取证与炸弹拦截、多公钥轮换签名目录与防降级/防重放、签名整目录增量与防篡改/防覆盖、Web Studio Node ESM 校验）：

```sh
# 完整验收（CLI + Web Studio Node ESM 测试；追加 --skip-web 可仅跑 CLI 验收）
python scripts/run_070_acceptance.py --cli _build/bin/windows/moonbsdiff.exe
python3 scripts/run_070_acceptance.py --cli _build/bin/linux/moonbsdiff
python3 scripts/run_070_acceptance.py --cli _build/bin/macos/moonbsdiff
```

### 多跳路线规划演示

离线更新演示脚本使用同一组样本文件比较三种更新策略，最后实际执行离线补丁链写出 `restored.bin`，并与独立目标文件逐字节核对：

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

- **MoonBit 工具链**：`moon 0.1.20261126`、`moonc v1.0.0-rc1+3c0520448`
- **Python**：构建、打包与演示脚本需 `3.10+`（CLI `unittest` 测试套件因使用 `contextlib.chdir` 需 `3.11+`）
- **Node.js**：运行 `--target js` 测试与 [Web Studio](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md) 校验所需
- **C 编译器**：原生 C 工具链（Windows 下请在已初始化的 MSVC 开发者终端中运行）

### 构建与验证

```sh
moon update
python scripts/build_cli.py --release
moon run cmd/example --target js
moon test --target native --deny-warn
python scripts/test_web_studio.py -v
```

构建脚本会输出原生可执行文件到 `_build/bin/windows/moonbsdiff.exe`、`_build/bin/linux/moonbsdiff` 或 `_build/bin/macos/moonbsdiff`。

发行打包覆盖 **4 个 CI 原生目标**（`windows-x86_64`、`linux-x86_64`、`linux-arm64`、`macos-arm64`），共产出 **6 个发布产物**（4 份归档 + `SHA256SUMS` + `build-info.json`）。由于上游 MoonBit `1.0.0-rc1` 未提供 `darwin-x86_64` 原生工具链，CI 不构建 Intel macOS（`macos-x86_64`）。

详见 [兼容性与 BSDiff 互操作说明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) 与 [CI 运行记录](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml)。

---

## 资源限制与安全边界

- **资源上限与炸弹预检** — 默认补丁生成接受最大 **64 KiB** 的旧/新输入并将补丁上限设为 **128 KiB**；默认应用与 `analyze_patch` 均采用失效关闭（fail-closed）策略，严格限制补丁体积、输出大小、累计解压字节数与控制指令数。详见 [大文件生成策略（256 KiB 与 1 MiB 实测）](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md) 与 [补丁预检取证](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md)。
- **内容完整性 vs. 发布者信任** — BSDIFF40 格式本身不含文件哈希，未签名清单仅校验 SHA-256 内容身份。验证发布者身份必须通过带外渠道固定可信 Ed25519 公钥（`TrustStore` / `--public-key`），校验域隔离的独立签名（`moonbsdiff-manifest-ed25519-v1\x00`、`moonbsdiff-catalog-ed25519-v1\x00`、`moonbsdiff-dir-manifest-ed25519-v1\x00`），并结合单调递增的 `min_catalog_version` 防重放与防降级路由策略。
- **无损交付与路径安全** — CLI 绝不覆盖现有文件或目录，目录增量操作拒绝遍历符号链接与 Windows 重解析点、拒绝越界及大小写冲突相对路径，并通过私有临时对象完成安全交付。详见 [交付与取消行为说明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md) 与 [目录增量包指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md)。

---

## 相关文档与参考

| 分类 | 文档链接 |
| --- | --- |
| **使用指南** | [CLI 安装指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli-install.md) · [CLI 参考手册](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/cli.md) · [库应用指南](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/apply.md) · [补丁预检取证](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/analyze.md) · [清单与签名](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/manifest.md) · [发布目录与轮换](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/catalog.md) · [目录增量包](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/dir-delta.md) · [流式文件交付](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/file-apply.md) |
| **交互与演示** | [Web Studio 工作台](https://github.com/BigSaltyMan/moonBSDiff/blob/master/examples/web-studio/README.md) · [0.7.0 综合验收脚本](https://github.com/BigSaltyMan/moonBSDiff/blob/master/scripts/run_070_acceptance.py) · [更新演示说明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/update-demo.md) |
| **技术参考** | [BSDIFF40 格式规范](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/format.md) · [SA-IS 后缀数组](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/suffix-array.md) · [大文件生成策略](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/generation-scales.md) · [基准测试](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/benchmarks.md) · [兼容性与互操作](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/compatibility.md) |
| **项目与发布** | [变更日志 (Changelog)](https://github.com/BigSaltyMan/moonBSDiff/blob/master/CHANGELOG.md) · [GitHub Releases](https://github.com/BigSaltyMan/moonBSDiff/releases) · [BSD-2-Clause 许可证](https://github.com/BigSaltyMan/moonBSDiff/blob/master/LICENSE) · [上游与第三方声明](https://github.com/BigSaltyMan/moonBSDiff/blob/master/docs/upstream.md) |
