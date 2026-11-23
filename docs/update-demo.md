# MoonBSDiff 项目验收

## 1. 解决什么问题

设备已有旧版本时，MoonBSDiff 按可信清单在完整文件和补丁路线之间选下载量更小的方案。设备已有补丁时，即使文件改了名，工具也能按实际大小和 SHA-256 找回可用路线。应用补丁时逐步核验内容身份，最后交付目标文件。

## 2. MoonBit 实现了什么

MoonBit 库实现 BSDIFF40 补丁生成与应用、清单核验和受跳数限制的路线规划。库接口支持 native、JS、Wasm-GC。Windows (`x86_64`)、Linux (`x86_64` / `arm64`) 和 macOS (`arm64`) 的 CLI 提供文件操作、总下载预算、离线选路和不覆盖交付。

算法与格式参考 Colin Percival 的 BSDiff 4.3，移植部分保留原版权与许可声明。项目采用 BSD-2-Clause，改编的 bzip2 组件保留 Apache-2.0 许可。详见[上游与第三方许可](upstream.md)和[项目许可证](../LICENSE)。

## 3. 怎样亲手验证

按 [README 快速验收](../README.md#快速验收)构建一次或取得适用的 CLI。在 Windows 运行下面这条命令；Linux (`x86_64` / `arm64`) 将路径换成 `_build/bin/linux/moonbsdiff`，macOS (`arm64`) 将路径换成 `_build/bin/macos/moonbsdiff`。当前源码树的 `scripts/run_update_demo.py` 校验引入公共前后缀快路径后的 `155` 字节 `v2-to-v3.patch`（两跳共 `359` 字节）路线；已发布的 `v0.5.0`–`v0.5.4` 二进制（如 [v0.5.0 Release](https://github.com/BigSaltyMan/moonBSDiff/releases/tag/v0.5.0)）早于该快路径，会生成 `164` 字节的 `v2-to-v3.patch`（两跳共 `368` 字节），验证这些旧版本时须使用对应 tag 下的 `scripts/run_update_demo.py`。

```sh
python scripts/run_update_demo.py --cli _build/bin/windows/moonbsdiff.exe
```

| 条件 | 实际选择 | 下载量 |
| --- | --- | ---: |
| 最多一跳 | 完整文件，直达补丁需要 2532 字节 | 2048 字节 |
| 最多两跳 | 204 字节和 155 字节的补丁 | 359 字节 |
| 已有两份改名、倒序传入的本地补丁 | `first.bin` 配 `v1-to-v2.json`，再用 `second.bin` 配 `v2-to-v3.json` | 0 字节 |

脚本从离线计划的 JSON 取出路径对，调用一次 `patch-chain`。看到 `UPDATE DEMO PASS` 时，可到打印的临时目录查看文件。`restored.bin` 与独立准备的 `v3.bin` 逐字节相同，大小为 **2048 字节**，SHA-256 为 `66da6542f8276608790055ac88e6af6bf3af76b88bf3aedbcb517c2ce98ab1a6`。

样本复用 [seeded-random 的旧、新文件和上游补丁](../testdata/upstream/seeded-random/)。`v3.bin` 来自 `v2.bin` 最后一个字节的最低位翻转。第二份补丁由 CLI 生成。2532 字节的直达补丁是刻意构造的合法 BSDIFF40 样本，完整目标放在 Extra 块，供比较规划决策。这个大小不作为常规 `diff` 的压缩成绩。

## 4. 证据在哪里

- 公开接口见[核心库](../pkg.generated.mbti)和[清单子包](../manifest/pkg.generated.mbti)。[双向互操作报告](compatibility.md)记录与真实 BSDiff 4.3 的 138 次完整字节比较。
- 演示见[脚本源码](../scripts/run_update_demo.py)和 [CI 工作流](../.github/workflows/ci.yml)。[运行记录](https://github.com/BigSaltyMan/moonBSDiff/actions/workflows/ci.yml)中选择与演示源码一致的提交，查看 Windows (`x86_64`)、Ubuntu (`x86_64` / `arm64`) 和 macOS (`arm64`) CLI 作业的 `Run the update planning and offline restore demo` 步骤。
- [v0.4.0 发布记录](release-0.4.0.md)固定了当时的源码、包和 CLI 资产。路由规划和离线恢复演示使用 v0.5.0 新增能力。公开的 v0.4.0 CLI 缺少这些命令。[v0.5.0 发布记录](release-0.5.0.md)分别记载源码和公开归档的演示证据。
