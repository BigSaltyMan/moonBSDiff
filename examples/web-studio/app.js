const MAX_PATCH_UPLOAD_BYTES = 2 * 1024 * 1024;
const DIR_MAX_FILES = 256;
const DIR_MAX_FILE_BYTES = 262144;
const DIR_MAX_TOTAL_BYTES = 4 * 1024 * 1024;

const I18N = {
  en: {
    subtitle: "Forensic & Verifiable Update Workbench — 100% Client-Side MoonBit JS Core",
    zero_backend_badge: "Zero Backend • Real Ed25519 + BSDIFF40",
    engine_loading: "Loading MoonBit JS Core...",
    engine_ready: "MoonBit JS Core v{version} • {count} modules",
    engine_missing: "dist/studio.js missing",
    boot_missing_title: "MoonBit JS Core not built yet (./dist/studio.js).",
    boot_missing_body: "Run python scripts/build_web_studio.py from the repository root, then serve examples/web-studio/ over HTTP (for example python -m http.server -d examples/web-studio 8080).",
    tab_graph_title: "Update Graph & Red-Team Lab",
    tab_graph_sub: "Ed25519 Catalog • Key Rotation • Dijkstra Routing",
    tab_xray_title: "BSDIFF40 X-Ray & Bomb Auditor",
    tab_xray_sub: "3-Stream Forensics • Risk Flags • Min Limits",
    tab_stream_title: "4 KiB Stream Oscilloscope",
    tab_stream_sub: "Bounded Chunks • Callback Trace • Fail-Closed Abort",
    tab_dir_title: "Directory Delta Explorer",
    tab_dir_sub: "Rename 0 B • Auto Fallback • Signed tree_sha256",
    graph_policy_heading: "Catalog Policy & Routing Controls",
    lbl_current_ver: "Current Release",
    lbl_target_ver: "Target Release",
    lbl_max_steps: "Max Hops (max_steps)",
    lbl_budget_cap: "Enforce Download Budget",
    lbl_allow_full: "Allow Full-File Fallback",
    lbl_min_cat: "Anti-Replay Floor",
    budget_unlimited: "Unlimited",
    graph_redteam_heading: "Red-Team & Rotation Scenarios",
    atk_none: "Normal Verified Update",
    atk_rotation: "Zero-Downtime Key Rotation",
    atk_poison: "Poison Fake Patch Edge",
    atk_downgrade: "Downgrade Attack → v1.0",
    atk_replay: "Replay Old Catalog (v3)",
    atk_tamper: "Tamper Hop Payload",
    graph_dag_heading: "Signed Release DAG & Active Route",
    graph_hops_heading: "Cryptographic Hop Verification Ledger",
    graph_catalog_json: "Inspect Real Signed ReleaseCatalog JSON",
    badge_signer: "SIGNER ",
    badge_trusted: "TRUSTED ",
    badge_cat_ver: "cat v{ver} ≥ {min}",
    kpi_decision: "Decision",
    kpi_verified_hops: "{count} verified hop(s)",
    kpi_download_payload: "Download Payload",
    kpi_full_target: "Full target: {size}",
    kpi_bandwidth_saved: "Bandwidth Saved",
    kpi_saved_sub: "{size} saved",
    kpi_catalog_sha: "Catalog SHA-256",
    kpi_channel: "channel: {channel}",
    graph_no_hops: "No patch hops executed for decision",
    th_hop: "Hop",
    th_transition: "Transition",
    th_patch_size: "Patch Size",
    th_patch_sha: "Patch SHA-256",
    th_restored_sha: "Restored SHA-256",
    th_status: "Status",
    pill_sha_ok: "SHA-256 OK",
    pill_rejected: "REJECTED",
    xray_input_heading: "Patch Source & Sandbox Limits",
    preset_healthy: "Healthy Firmware Update",
    preset_healthy_desc: "8 KiB structured edit • Low risk",
    preset_fastpath: "Fast-Path Prefix / Suffix",
    preset_fastpath_desc: "4 KiB identical flanks • 2 controls",
    preset_bomb: "Bzip2 Decompression Bomb",
    preset_bomb_desc: "~140 B → 100 KiB (>700× expansion)",
    preset_random: "Incompressible Random",
    preset_random_desc: "Patch ≥ Output + High Extra Share",
    preset_reorder: "Reordered Blocks (Neg Seeks)",
    preset_reorder_desc: "24 reversed chunks • negative seek_offset",
    preset_trunc: "Truncated / Corrupt Patch",
    preset_trunc_desc: "Structured BsdiffError::TruncatedData",
    xray_drop_title: "Drop ANY real .patch file here",
    xray_drop_sub: "or click to browse — analyzed locally via MoonBit JS",
    xray_browse: "Select .patch File",
    xray_limits_heading: "Resource Limit Policy",
    lim_generous: "Generous Audit",
    lim_tight: "Tight Sandbox (8 KiB)",
    lim_balanced: "Balanced",
    xray_reanalyze: "Re-Analyze with Limits",
    xray_download: "Download .patch",
    xray_report_heading: "BSDIFF40 Structural X-Ray & Risk Audit",
    xray_bar_heading: "Segmented Wire Layout (32 B Header + 3 Bzip2 Streams)",
    xray_flags_heading: "Preflight Security Risk Flags",
    xray_controls_heading: "Decoded Control Tuples (add / extra / seek)",
    xray_mbt_heading: "Minimum Required MoonBit Limits",
    xray_cli_heading: "Hardened CLI Preflight Command",
    xray_rejected_pill: "REJECTED • {kind}",
    xray_fail_closed: "FAIL-CLOSED REJECTED",
    xray_field: "Field:",
    xray_value: "Value:",
    xray_limit: "Limit:",
    xray_risk_pill: "RISK: {level}",
    xray_risk_low: "LOW",
    xray_risk_elevated: "ELEVATED",
    xray_risk_high: "HIGH",
    xray_wire_total: "{patch} B wire → {output} B output",
    kpi_expansion_ratio: "Expansion Ratio",
    kpi_patch_output: "Patch / Output",
    kpi_diff_extra_share: "Diff vs Extra Share",
    kpi_diff_extra_sub: "diff {diff} B • extra {extra} B",
    kpi_controls_seeks: "Controls & Neg Seeks",
    kpi_max_abs_seek: "max |seek|: {val}",
    xray_clean_pill: "CLEAN",
    xray_clean_desc: "Zero preflight risk flags raised — patch is well-behaved under BSDIFF40 policy.",
    xray_showing_controls: "showing {shown} of {total} controls",
    th_idx: "Idx",
    th_add_diff: "Add (diff)",
    th_extra: "Extra",
    th_mix: "Mix",
    th_seek_offset: "Seek Offset",
    err_patch_too_large: "File \"{name}\" ({size} B) exceeds {limit} B (2 MiB) interactive studio upload cap.",
    err_limit_not_int: "Limit field \"{field}\" must be a finite integer (received \"{value}\").",
    btn_copy: "Copy",
    btn_copied: "Copied!",
    stream_controls_heading: "Streaming Engine Controls",
    stream_preset_lbl: "Stream Payload Scenario",
    stream_opt_fw: "Firmware 20 KiB (5× 4 KiB chunks)",
    stream_opt_mixed: "Mixed Insert 24 KiB (diff + extra streams)",
    stream_opt_reorder: "Reordered 16 KiB (non-sequential seeks)",
    stream_abort_lbl: "Abort After Chunk N (Fail-Closed Test)",
    stream_abort_complete: "0 (Complete)",
    stream_abort_after: "After chunk #{n}",
    stream_playback_heading: "Oscilloscope Playback",
    btn_play: "Play",
    btn_pause: "Pause",
    btn_reset: "Reset",
    stream_cursor_lbl: "Frame / Chunk Cursor",
    stream_scope_heading: "Bounded 4 KiB Chunk Waveform & Stage Pipeline",
    stream_trace_heading: "Real Callback Event Trace (read_old_at / read_patch_at / write_output)",
    stream_pill_verified: "VERIFIED STREAM • SHA-256 MATCH",
    stream_pill_cancelled: "FAIL-CLOSED CANCELLED",
    stream_pill_error: "ERROR • {kind}",
    stage_hdr_name: "1. HeaderVerified",
    stage_hdr_sub: "32 B prefix checked",
    stage_restore_name: "2. Restoring",
    stage_restore_sub: "≤ 4096 B chunks",
    stage_validate_name: "3. Validating",
    stage_validate_sub: "EOF & CRC tail check",
    stage_aborted_name: "4. Aborted",
    stage_verified_name: "4. SHA-256 Verified",
    stage_delivered_sub: "Delivered atomically",
    stage_uncommitted_sub: "0 corrupted output committed",
    stream_verdict_ok_pill: "STREAM RESTORED",
    stream_verdict_ok_summary: "Completed {chunks} bounded write_output chunks (peak {peak} B ≤ 4096 B ceiling) with exact byte-for-byte SHA-256 verification.",
    stream_verdict_abort_pill: "FAIL-CLOSED ABORT",
    stream_verdict_abort_summary: "Halted cleanly after {chunks} chunks ({written} staged); final_delivered=false — target file untouched.",
    stream_verdict_err_pill: "STREAM REJECTED",
    stream_verdict_err_summary: "Streaming apply failed closed ({detail}); final_delivered=false.",
    cnt_write_chunks: "write_output chunks",
    cnt_bytes_emitted: "Bytes Emitted",
    cnt_read_old: "read_old_at calls",
    cnt_read_patch: "read_patch_at calls",
    cnt_total_paren: "{shown} (total {total})",
    cnt_peak_chunk: "Peak Chunk Size",
    cnt_checkpoints: "Checkpoints",
    svg_stream_ceiling: "4096 B HARD STREAM BUFFER CEILING",
    svg_stream_aborted: "ABORTED",
    kpi_old_patch_target: "Old / Patch / Target",
    kpi_real_diff: "Real @moonbsdiff.diff",
    kpi_peak_chunk: "Peak Chunk",
    kpi_ceiling_4096: "Ceiling: 4096 B",
    kpi_target_sha: "Target SHA-256",
    kpi_exact_match: "Exact Match",
    kpi_not_committed: "Not Committed",
    kpi_delivery_state: "Delivery State",
    kpi_committed: "COMMITTED",
    kpi_discarded: "DISCARDED",
    kpi_fail_closed_io: "Fail-Closed Io",
    kpi_verified: "Verified",
    kpi_rejected: "Rejected",
    stream_events_recorded: "{count} recorded callbacks",
    th_callback: "Callback",
    th_detail: "Detail",
    th_offset: "Offset",
    th_written: "Written",
    dir_controls_heading: "Directory Trees & Tamper Tests",
    dir_btn_preset: "Load Mini App v1 → v2 Preset",
    dir_pick_old: "Old Folder (v1)",
    dir_pick_new: "New Folder (v2)",
    dir_none_selected: "Preset active",
    dir_files_loaded: "{count} files loaded ({size})",
    dir_err_too_many_files: "Folder has {count} files, exceeding the {limit}-file interactive studio cap.",
    dir_err_file_too_large: "File \"{path}\" exceeds 256 KiB interactive studio cap.",
    dir_err_total_too_large: "Folder total size ({size}) exceeds 4 MiB interactive studio cap.",
    dir_run_custom: "Diff & Sign Selected Folders",
    dir_tamper_heading: "Signed Bundle Attack Simulation",
    dir_tm_none: "Clean Ed25519 Verified Apply",
    dir_tm_blob: "Tamper Patch Blob (1-Byte Flip)",
    dir_tm_sig: "Forge Ed25519 Signature",
    dir_tm_path: "Inject Path Traversal (../escape.sh)",
    dir_report_heading: "File-Level Delta Plan & Tree Authenticity",
    dir_manifest_json: "Inspect Canonical Signed dir-manifest.json",
    dir_signer_prefix: "Ed25519 key_id: {kid}",
    dir_hash_old: "old_tree_sha256",
    dir_hash_new_manifest: "new_tree_sha256 (manifest)",
    dir_hash_restored: "restored_tree_sha256",
    dir_hash_aborted: "ABORTED (not committed)",
    kpi_transfer_delta: "Transfer Delta",
    kpi_vs_full: "vs {size} full",
    kpi_total_savings: "Total Savings",
    kpi_avoided: "{size} avoided",
    kpi_zero_byte_moves: "Zero-Byte Moves",
    kpi_eq_ren: "{unchanged} eq / {renamed} ren",
    kpi_zero_transferred: "0 B transferred",
    kpi_patched_fallback: "Patched / Fallback",
    kpi_added_del: "added {added} • del {deleted}",
    th_action: "Action",
    th_rel_path: "Relative Path",
    th_old: "Old",
    th_new: "New",
    th_payload: "Payload",
    th_saved: "Saved",
    th_blob: "Blob",
    pill_tampered: "TAMPERED",
    dir_table_empty: "No directory delta entries available for this result.",
    dir_table_filtered_empty: "No entries match filter {filter}.",
    flt_all: "All",
    footer_left: "Powered by BigSaltyMan/moonbsdiff compiled to ES Module via MoonBit JS target — zero external dependencies.",
  },
  zh: {
    subtitle: "可验证增量更新与补丁取证工作台 — 100% 浏览器本地 MoonBit JS 核心驱动",
    zero_backend_badge: "零后端 • 真 Ed25519 验签 + BSDIFF40",
    engine_loading: "正在加载 MoonBit JS 核心...",
    engine_ready: "MoonBit JS 核心 v{version} • {count} 个模块",
    engine_missing: "缺少 dist/studio.js",
    boot_missing_title: "尚未构建 MoonBit JS 核心（./dist/studio.js）。",
    boot_missing_body: "请在仓库根目录运行 python scripts/build_web_studio.py，然后通过 HTTP 启动 examples/web-studio/（例如 python -m http.server -d examples/web-studio 8080）。",
    tab_graph_title: "更新图谱与攻防演练",
    tab_graph_sub: "Ed25519 目录 • 密钥轮换 • Dijkstra 路由",
    tab_xray_title: "BSDIFF40 三流透视与炸弹体检",
    tab_xray_sub: "三流解构 • 风险标记 • 最小 Limits 生成",
    tab_stream_title: "4 KiB 流式还原示波器",
    tab_stream_sub: "有界分块 • 回调轨迹 • 失败即停演练",
    tab_dir_title: "目录级增量更新对比",
    tab_dir_sub: "0 B 重命名 • 自动回退 • 签名 tree_sha256",
    graph_policy_heading: "发布目录策略与路由控制",
    lbl_current_ver: "当前版本",
    lbl_target_ver: "目标版本",
    lbl_max_steps: "最大跳数 (max_steps)",
    lbl_budget_cap: "启用下载预算上限",
    lbl_allow_full: "允许回退完整包",
    lbl_min_cat: "防重放目录版本下限",
    budget_unlimited: "不限",
    graph_redteam_heading: "红蓝攻防与密钥轮换演练",
    atk_none: "正常签名更新",
    atk_rotation: "零停机密钥轮换",
    atk_poison: "投毒伪造超小补丁边",
    atk_downgrade: "降级攻击 → v1.0",
    atk_replay: "重放旧签名目录 (v3)",
    atk_tamper: "篡改单跳补丁载荷",
    graph_dag_heading: "签名发布图谱 (DAG) 与实时激活路径",
    graph_hops_heading: "逐跳 SHA-256 还原验证账本",
    graph_catalog_json: "查看真实签名 ReleaseCatalog JSON",
    badge_signer: "签名密钥 ",
    badge_trusted: "信任密钥 ",
    badge_cat_ver: "目录 v{ver} ≥ {min}",
    kpi_decision: "路由决策",
    kpi_verified_hops: "已验证 {count} 跳",
    kpi_download_payload: "下载载荷",
    kpi_full_target: "完整目标包：{size}",
    kpi_bandwidth_saved: "节省带宽",
    kpi_saved_sub: "节省 {size}",
    kpi_catalog_sha: "目录 SHA-256",
    kpi_channel: "通道：{channel}",
    graph_no_hops: "当前决策未执行增量补丁跳数：",
    th_hop: "跳次",
    th_transition: "版本跃迁",
    th_patch_size: "补丁大小",
    th_patch_sha: "补丁 SHA-256",
    th_restored_sha: "还原 SHA-256",
    th_status: "状态",
    pill_sha_ok: "SHA-256 通过",
    pill_rejected: "已拦截",
    xray_input_heading: "补丁来源与沙箱资源上限",
    preset_healthy: "健康固件增量更新",
    preset_healthy_desc: "8 KiB 结构化修改 • 低风险",
    preset_fastpath: "快路径前后缀匹配",
    preset_fastpath_desc: "4 KiB 相同首尾 • 2 条控制指令",
    preset_bomb: "Bzip2 解压炸弹",
    preset_bomb_desc: "~140 B → 100 KiB (>700× 膨胀)",
    preset_random: "不可压缩随机数据",
    preset_random_desc: "补丁 ≥ 输出 + 高 Extra 占比",
    preset_reorder: "重排块（含负向 Seek）",
    preset_reorder_desc: "24 个逆序块 • 负向 seek_offset",
    preset_trunc: "截断 / 损坏补丁",
    preset_trunc_desc: "结构化 BsdiffError::TruncatedData",
    xray_drop_title: "拖拽任意真实 .patch 文件到此处",
    xray_drop_sub: "或点击选择文件 — 全部在本地 MoonBit JS 引擎中体检",
    xray_browse: "选择 .patch 文件",
    xray_limits_heading: "资源配额预设",
    lim_generous: "宽松审计",
    lim_tight: "严格沙箱 (8 KiB 解压上限)",
    lim_balanced: "均衡策略",
    xray_reanalyze: "按当前配额重新体检",
    xray_download: "下载当前 .patch",
    xray_report_heading: "BSDIFF40 结构透视与安全风险审计",
    xray_bar_heading: "二进制线格式分段（32 B 头部 + 三条 Bzip2 流）",
    xray_flags_heading: "预检安全风险标记",
    xray_controls_heading: "解码控制三元组 (add / extra / seek)",
    xray_mbt_heading: "最小可行 MoonBit Limits 配置",
    xray_cli_heading: "加固 CLI 预检命令",
    xray_rejected_pill: "已拦截 • {kind}",
    xray_fail_closed: "安全拦截（FAIL-CLOSED）",
    xray_field: "字段：",
    xray_value: "实际值：",
    xray_limit: "上限：",
    xray_risk_pill: "风险等级：{level}",
    xray_risk_low: "低",
    xray_risk_elevated: "中",
    xray_risk_high: "高",
    xray_wire_total: "{patch} B 线格式 → {output} B 输出",
    kpi_expansion_ratio: "解压膨胀率",
    kpi_patch_output: "补丁 / 输出比",
    kpi_diff_extra_share: "Diff / Extra 占比",
    kpi_diff_extra_sub: "diff {diff} B • extra {extra} B",
    kpi_controls_seeks: "控制数 / 负向 Seek",
    kpi_max_abs_seek: "最大 |seek|：{val}",
    xray_clean_pill: "安全",
    xray_clean_desc: "未触发预检安全风险标记 — 补丁符合 BSDIFF40 安全策略。",
    xray_showing_controls: "展示 {shown} / {total} 条控制指令",
    th_idx: "序号",
    th_add_diff: "Add (diff)",
    th_extra: "Extra",
    th_mix: "占比分布",
    th_seek_offset: "Seek 偏移",
    err_patch_too_large: "文件 \"{name}\"（{size} B）超过交互工作台 2 MiB（{limit} B）上传上限。",
    err_limit_not_int: "资源配额字段 \"{field}\" 必须为有限整数（当前输入：\"{value}\"）。",
    btn_copy: "复制",
    btn_copied: "已复制",
    stream_controls_heading: "流式还原引擎控制",
    stream_preset_lbl: "流式样本场景",
    stream_opt_fw: "固件 20 KiB（5× 4 KiB 分块）",
    stream_opt_mixed: "混合插入 24 KiB（diff + extra 流）",
    stream_opt_reorder: "重排 16 KiB（非顺序 Seek）",
    stream_abort_lbl: "在第 N 块后中止（Fail-Closed 验证）",
    stream_abort_complete: "0 (完整还原)",
    stream_abort_after: "第 #{n} 块后中止",
    stream_playback_heading: "示波器回放控制",
    btn_play: "播放",
    btn_pause: "暂停",
    btn_reset: "重置",
    stream_cursor_lbl: "分块播放游标",
    stream_scope_heading: "4 KiB 有界分块波形与阶段流水线",
    stream_trace_heading: "真实回调事件轨迹 (read_old_at / read_patch_at / write_output)",
    stream_pill_verified: "流式校验通过 • SHA-256 一致",
    stream_pill_cancelled: "失败即停 • 已中止",
    stream_pill_error: "错误 • {kind}",
    stage_hdr_name: "1. HeaderVerified",
    stage_hdr_sub: "已校验 32 B 头部",
    stage_restore_name: "2. Restoring",
    stage_restore_sub: "≤ 4096 B 有界分块",
    stage_validate_name: "3. Validating",
    stage_validate_sub: "EOF 与尾部 CRC 校验",
    stage_aborted_name: "4. 已中止",
    stage_verified_name: "4. SHA-256 校验通过",
    stage_delivered_sub: "原子化提交完成",
    stage_uncommitted_sub: "零损坏输出被提交",
    stream_verdict_ok_pill: "流式还原完成",
    stream_verdict_ok_summary: "已完成 {chunks} 个有界 write_output 分块（峰值 {peak} B ≤ 4096 B 上限），且 SHA-256 逐字节一致。",
    stream_verdict_abort_pill: "FAIL-CLOSED 中止",
    stream_verdict_abort_summary: "在第 {chunks} 块（暂存 {written}）后干净中止；final_delivered=false — 目标文件未被修改。",
    stream_verdict_err_pill: "流式请求被拒绝",
    stream_verdict_err_summary: "流式还原已安全拒绝（{detail}）；final_delivered=false。",
    cnt_write_chunks: "write_output 分块",
    cnt_bytes_emitted: "已输出字节",
    cnt_read_old: "read_old_at 次数",
    cnt_read_patch: "read_patch_at 次数",
    cnt_total_paren: "{shown}（共 {total}）",
    cnt_peak_chunk: "峰值分块大小",
    cnt_checkpoints: "检查点调用",
    svg_stream_ceiling: "4096 B 流式缓冲硬上限",
    svg_stream_aborted: "已中止",
    kpi_old_patch_target: "旧文件 / 补丁 / 目标",
    kpi_real_diff: "真实 @moonbsdiff.diff",
    kpi_peak_chunk: "峰值分块",
    kpi_ceiling_4096: "硬上限：4096 B",
    kpi_target_sha: "目标 SHA-256",
    kpi_exact_match: "完全一致",
    kpi_not_committed: "未提交",
    kpi_delivery_state: "交付状态",
    kpi_committed: "已提交",
    kpi_discarded: "已丢弃",
    kpi_fail_closed_io: "失败即停 Io",
    kpi_verified: "校验通过",
    kpi_rejected: "已拒绝",
    stream_events_recorded: "共记录 {count} 次回调",
    th_callback: "回调事件",
    th_detail: "详情",
    th_offset: "偏移",
    th_written: "累计写入",
    dir_controls_heading: "目录树选择与篡改攻防",
    dir_btn_preset: "载入 Mini App v1 → v2 预设",
    dir_pick_old: "选择旧目录 (v1)",
    dir_pick_new: "选择新目录 (v2)",
    dir_none_selected: "当前使用内置预设",
    dir_files_loaded: "已加载 {count} 个文件（{size}）",
    dir_err_too_many_files: "目录包含 {count} 个文件，超过工作台 {limit} 个文件上限。",
    dir_err_file_too_large: "文件 \"{path}\" 超过工作台 256 KiB 单文件上限。",
    dir_err_total_too_large: "目录总大小（{size}）超过工作台 4 MiB 总容量上限。",
    dir_run_custom: "对比并签名所选本地目录",
    dir_tamper_heading: "签名目录包安全攻防测试",
    dir_tm_none: "正常 Ed25519 验签还原",
    dir_tm_blob: "篡改补丁 Blob（翻转 1 字节）",
    dir_tm_sig: "伪造 Ed25519 签名",
    dir_tm_path: "注入路径穿越 (../escape.sh)",
    dir_report_heading: "文件级增量清单与整树哈希校验",
    dir_manifest_json: "查看规范化签名 dir-manifest.json",
    dir_signer_prefix: "Ed25519 密钥 ID：{kid}",
    dir_hash_old: "旧目录 tree_sha256",
    dir_hash_new_manifest: "新目录 tree_sha256（清单）",
    dir_hash_restored: "还原目录 tree_sha256",
    dir_hash_aborted: "已中止（未提交）",
    kpi_transfer_delta: "增量传输载荷",
    kpi_vs_full: "完整包 {size}",
    kpi_total_savings: "总带宽节省",
    kpi_avoided: "减少传输 {size}",
    kpi_zero_byte_moves: "零字节复用",
    kpi_eq_ren: "{unchanged} 未变 / {renamed} 重命名",
    kpi_zero_transferred: "0 B 传输",
    kpi_patched_fallback: "补丁 / 回退完整包",
    kpi_added_del: "新增 {added} • 删除 {deleted}",
    th_action: "动作",
    th_rel_path: "相对路径",
    th_old: "旧大小",
    th_new: "新大小",
    th_payload: "传输载荷",
    th_saved: "节省率",
    th_blob: "Blob 文件",
    pill_tampered: "已篡改",
    dir_table_empty: "当前结果没有可展示的目录增量条目。",
    dir_table_filtered_empty: "筛选条件 {filter} 下无匹配条目。",
    flt_all: "全部",
    footer_left: "由 BigSaltyMan/moonbsdiff 编译至 MoonBit JS 原生 ES 模块驱动 — 零后端、零外部依赖。",
  },
};

const state = {
  lang: "en",
  studio: null,
  studioInfo: null,
  bootError: null,
  graph: {
    attack_mode: "none",
    lastData: null,
  },
  xray: {
    mode: "preset",
    preset: "healthy_update",
    limitPreset: "generous",
    customHex: null,
    customName: "",
    lastPatchHex: null,
    lastPatchName: "healthy_update.patch",
    lastData: null,
    uploadSeq: 0,
  },
  stream: {
    preset: "firmware_20k",
    abortAfter: 0,
    presetChunkCounts: {},
    data: null,
    cursor: 0,
    timer: null,
  },
  dir: {
    mode: "preset",
    tamper: "none",
    filter: "ALL",
    customOld: null,
    customNew: null,
    oldSeq: 0,
    newSeq: 0,
    oldStatus: { kind: "preset" },
    newStatus: { kind: "preset" },
    lastData: null,
  },
};

const $ = (id) => document.getElementById(id);

function t(key, vars = null) {
  const dict = I18N[state.lang] || I18N.en;
  const msg = dict[key] ?? I18N.en[key] ?? key;
  if (!vars) return msg;
  return msg.replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : match
  );
}

function escapeHtml(str) {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function fmtBytes(n) {
  if (n === null || n === undefined || Number.isNaN(Number(n))) return "—";
  const v = Number(n);
  if (Math.abs(v) >= 1024 * 1024) return `${(v / (1024 * 1024)).toFixed(2)} MiB (${v.toLocaleString()} B)`;
  if (Math.abs(v) >= 4096) return `${(v / 1024).toFixed(1)} KiB (${v.toLocaleString()} B)`;
  return `${v.toLocaleString()} B`;
}

function fmtCompactBytes(n) {
  const v = Number(n);
  if (Math.abs(v) >= 1024 * 1024) return `${(v / (1024 * 1024)).toFixed(2)} MiB`;
  if (Math.abs(v) >= 1024) return `${(v / 1024).toFixed(1)} KiB`;
  return `${v} B`;
}

function fmtPct(permille) {
  return `${(Number(permille || 0) / 10).toFixed(1)}%`;
}

function shortHash(h, n = 14) {
  if (!h) return "—";
  return h.length > n ? `${h.slice(0, n)}…` : h;
}

function bytesToHex(u8) {
  let out = "";
  for (let i = 0; i < u8.length; i++) {
    out += u8[i].toString(16).padStart(2, "0");
  }
  return out;
}

function hexToBytes(hex) {
  if (typeof hex !== "string") {
    throw new Error("Invalid hex string: expected string");
  }
  const clean = hex.replace(/\s+/g, "");
  if (clean.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(clean)) {
    throw new Error("Invalid hex string: must have even length and hex digits [0-9a-fA-F]");
  }
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function renderEngineBadge() {
  const badge = $("engine-badge");
  if (!badge) return;
  if (state.studioInfo) {
    badge.textContent = t("engine_ready", {
      version: state.studioInfo.studio_version,
      count: (state.studioInfo.capabilities || []).length,
    });
  } else if (state.bootError) {
    badge.textContent = t("engine_missing");
  } else {
    badge.textContent = t("engine_loading");
  }
}

function renderBootBanner() {
  const banner = $("boot-banner");
  if (!banner) return;
  if (!state.bootError) {
    banner.classList.add("hidden");
    return;
  }
  banner.classList.remove("hidden");
  banner.innerHTML =
    `<strong>${escapeHtml(t("boot_missing_title"))}</strong> ` +
    `${escapeHtml(t("boot_missing_body"))} ` +
    `<br><span class="mono">${escapeHtml(state.bootError)}</span>`;
}

function formatDirStatus(status) {
  if (!status || status.kind === "preset") {
    return t("dir_none_selected");
  }
  if (status.kind === "loaded") {
    return t("dir_files_loaded", {
      count: status.count,
      size: fmtCompactBytes(status.totalBytes),
    });
  }
  if (status.kind === "error") {
    if (status.i18nKey) {
      return t(status.i18nKey, status.vars);
    }
    return status.message || "";
  }
  return t("dir_none_selected");
}

function renderDirPickerStatus() {
  const oldEl = $("dir-old-status");
  const newEl = $("dir-new-status");
  if (oldEl) oldEl.textContent = formatDirStatus(state.dir.oldStatus);
  if (newEl) newEl.textContent = formatDirStatus(state.dir.newStatus);
}

function updateGraphBudgetDisplay() {
  const budgetEnabled = $("graph-budget-enabled").checked;
  const budgetVal = Number($("graph-budget").value);
  $("graph-budget").disabled = !budgetEnabled;
  $("graph-budget-val").textContent = budgetEnabled ? fmtBytes(budgetVal) : t("budget_unlimited");
  $("graph-max-steps-val").textContent = $("graph-max-steps").value;
}

function applyLanguage() {
  const dict = I18N[state.lang] || I18N.en;
  document.documentElement.lang = state.lang === "zh" ? "zh-CN" : "en";
  document.querySelectorAll("[data-i18n]").forEach((el) => {
    const key = el.getAttribute("data-i18n");
    if (dict[key]) el.textContent = dict[key];
  });
  const playBtn = $("stream-play");
  if (playBtn) {
    playBtn.textContent = state.stream.timer ? dict.btn_pause : dict.btn_play;
  }
  renderEngineBadge();
  renderBootBanner();
  updateGraphBudgetDisplay();
  renderDirPickerStatus();
}

/* ==================== TAB 1: UPDATE GRAPH ==================== */

function parseStrictIntOrFallback(rawStr, fallback) {
  const trimmed = String(rawStr ?? "").trim();
  if (/^[+-]?\d+$/.test(trimmed)) {
    const num = Number(trimmed);
    if (Number.isSafeInteger(num)) return num;
  }
  return fallback;
}

function runGraph() {
  if (!state.studio) return;
  const budgetEnabled = $("graph-budget-enabled").checked;
  const budgetVal = Number($("graph-budget").value);
  updateGraphBudgetDisplay();

  const req = {
    current_version: Number($("graph-current").value),
    target_version: Number($("graph-target").value),
    max_steps: Number($("graph-max-steps").value),
    max_download_bytes: budgetEnabled ? budgetVal : null,
    allow_full: $("graph-allow-full").checked,
    attack_mode: state.graph.attack_mode,
    min_catalog_version: parseStrictIntOrFallback($("graph-min-catalog").value, 1),
  };
  const data = JSON.parse(state.studio.studio_run_graph_scenario(JSON.stringify(req)));
  state.graph.lastData = data;
  renderGraph(data);
}

function renderGraph(data) {
  if (!data) return;

  // Sync Tab 1 controls with backend effective overrides (e.g. downgrade_v1, replay_old_catalog, tamper_hop)
  if (data.current_version !== null && data.current_version !== undefined) {
    const curStr = String(data.current_version);
    if ($("graph-current").value !== curStr && $("graph-current").querySelector(`option[value="${curStr}"]`)) {
      $("graph-current").value = curStr;
    }
  }
  if (data.target_version !== null && data.target_version !== undefined) {
    const tgtStr = String(data.target_version);
    if ($("graph-target").value !== tgtStr && $("graph-target").querySelector(`option[value="${tgtStr}"]`)) {
      $("graph-target").value = tgtStr;
    }
  }
  if (data.min_catalog_version !== null && data.min_catalog_version !== undefined) {
    const minEl = $("graph-min-catalog");
    const minStr = String(data.min_catalog_version);
    if (document.activeElement !== minEl && minEl.value !== minStr) {
      minEl.value = minStr;
    }
  }
  if (data.attack_mode === "tamper_hop") {
    if (data.effective_max_steps !== null && data.effective_max_steps !== undefined) {
      const stepsStr = String(data.effective_max_steps);
      if ($("graph-max-steps").value !== stepsStr) {
        $("graph-max-steps").value = stepsStr;
        $("graph-max-steps-val").textContent = stepsStr;
      }
    }
    if (typeof data.allow_full === "boolean" && $("graph-allow-full").checked !== data.allow_full) {
      $("graph-allow-full").checked = data.allow_full;
    }
  }

  // Trust badges
  const badges = [];
  for (const kid of data.trusted_key_ids || []) {
    const isSigner = kid === data.signer_key_id;
    badges.push(
      `<span class="pill ${isSigner ? "pill-ok" : "pill-info"} mono">${escapeHtml(isSigner ? t("badge_signer") : t("badge_trusted"))}${escapeHtml(kid)}</span>`
    );
  }
  if (data.catalog_version !== null && data.catalog_version !== undefined) {
    badges.push(
      `<span class="mono-tag">${escapeHtml(t("badge_cat_ver", { ver: data.catalog_version, min: data.min_catalog_version ?? "—" }))}</span>`
    );
  }
  $("graph-trust-badges").innerHTML = badges.join("");

  // Verdict banner
  const v = data.security_verdict || {
    status: "BLOCKED",
    code: "InvalidRequest",
    summary: "",
    raw_error: "",
  };
  const cls = v.status === "VERIFIED" ? "verified" : v.status === "BLOCKED" ? "blocked" : "policy";
  const pillCls = v.status === "VERIFIED" ? "pill-ok" : v.status === "BLOCKED" ? "pill-danger" : "pill-warn";
  $("graph-verdict").className = `verdict-banner ${cls}`;
  $("graph-verdict").innerHTML = `
    <div class="verdict-head">
      <span class="pill ${pillCls}">${escapeHtml(v.status)}</span>
      <span class="verdict-code">${escapeHtml(v.code)}</span>
    </div>
    <p class="verdict-summary">${escapeHtml(v.summary)}</p>
    ${v.raw_error ? `<p class="verdict-raw">${escapeHtml(v.raw_error)}</p>` : ""}
  `;

  // Render SVG DAG
  const coords = {
    1: { x: 95, y: 155 },
    2: { x: 285, y: 155 },
    3: { x: 475, y: 155 },
    4: { x: 665, y: 155 },
  };
  const svgParts = [
    `<defs>
      <marker id="arr-dim" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M 0 1 L 10 5 L 0 9 z" fill="#475569"/></marker>
      <marker id="arr-ok" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 1 L 10 5 L 0 9 z" fill="#34d399"/></marker>
      <marker id="arr-bad" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 1 L 10 5 L 0 9 z" fill="#fb7185"/></marker>
    </defs>`,
  ];

  // Draw edges
  for (const e of data.patches || []) {
    const a = coords[e.from_version];
    const b = coords[e.to_version];
    if (!a || !b) continue;
    const span = e.to_version - e.from_version;
    let d;
    let lx;
    let ly;
    if (span === 1) {
      d = `M ${a.x + 42} ${a.y} L ${b.x - 44} ${b.y}`;
      lx = (a.x + b.x) / 2;
      ly = a.y - 12;
    } else if (span === 2 && e.from_version === 1) {
      d = `M ${a.x + 28} ${a.y - 30} Q ${(a.x + b.x) / 2} 34 ${b.x - 28} ${b.y - 30}`;
      lx = (a.x + b.x) / 2;
      ly = 56;
    } else if (span === 2 && e.from_version === 2) {
      d = `M ${a.x + 28} ${a.y + 30} Q ${(a.x + b.x) / 2} 252 ${b.x - 28} ${b.y + 30}`;
      lx = (a.x + b.x) / 2;
      ly = 236;
    } else {
      // span === 3 poisoned express edge
      d = `M ${a.x + 20} ${a.y - 34} Q ${(a.x + b.x) / 2} -6 ${b.x - 20} ${b.y - 34}`;
      lx = (a.x + b.x) / 2;
      ly = 22;
    }
    const isDanger = e.poisoned || e.tampered;
    const stroke = isDanger ? "#fb7185" : e.active ? "#34d399" : "#334155";
    const width = isDanger || e.active ? 3 : 1.75;
    const dash = e.poisoned ? 'stroke-dasharray="7 5"' : e.tampered ? 'stroke-dasharray="4 3"' : "";
    const marker = isDanger ? "url(#arr-bad)" : e.active ? "url(#arr-ok)" : "url(#arr-dim)";
    const label = e.poisoned
      ? `POISONED ${e.patch_bytes} B`
      : e.tampered
      ? `TAMPERED HOP #${e.hop_order}`
      : e.active
      ? `HOP ${e.hop_order} • ${e.patch_bytes} B`
      : `${e.patch_bytes} B`;
    svgParts.push(`<path d="${d}" fill="none" stroke="${stroke}" stroke-width="${width}" ${dash} marker-end="${marker}"/>`);
    svgParts.push(
      `<rect x="${lx - 54}" y="${ly - 12}" width="108" height="20" rx="10" fill="#091020" stroke="${stroke}" stroke-width="1"/>` +
      `<text x="${lx}" y="${ly + 2}" text-anchor="middle" fill="${isDanger ? "#fecdd3" : e.active ? "#6ee7b7" : "#94a3b8"}" font-family="monospace" font-size="10.5" font-weight="700">${escapeHtml(label)}</text>`
    );
  }

  // Draw release nodes
  for (const r of data.releases || []) {
    const p = coords[r.version];
    if (!p) continue;
    const stroke = r.revoked
      ? "#fb7185"
      : r.is_target
      ? "#34d399"
      : r.is_current
      ? "#38bdf8"
      : "#475569";
    const fill = r.revoked
      ? "rgba(244,63,94,0.16)"
      : r.is_target
      ? "rgba(16,185,129,0.16)"
      : r.is_current
      ? "rgba(56,189,248,0.16)"
      : "#111c32";
    const roleTag = r.revoked
      ? "REVOKED"
      : r.is_current && r.is_target
      ? "CURRENT=TARGET"
      : r.is_current
      ? "CURRENT"
      : r.is_target
      ? "TARGET"
      : `v#${r.version}`;
    svgParts.push(
      `<g>
        <rect x="${p.x - 42}" y="${p.y - 32}" width="84" height="64" rx="12" fill="${fill}" stroke="${stroke}" stroke-width="2.2"/>
        <text x="${p.x}" y="${p.y - 8}" text-anchor="middle" fill="#f8fafc" font-family="monospace" font-size="13" font-weight="700">${escapeHtml(r.label)}</text>
        <text x="${p.x}" y="${p.y + 8}" text-anchor="middle" fill="#94a3b8" font-family="monospace" font-size="10">${fmtCompactBytes(r.size_bytes)}</text>
        <text x="${p.x}" y="${p.y + 23}" text-anchor="middle" fill="${stroke}" font-family="monospace" font-size="9" font-weight="700">${roleTag}</text>
      </g>`
    );
  }
  $("graph-svg").innerHTML = svgParts.join("");

  // KPIs
  const verifiedSteps = Array.isArray(data.verified_steps) ? data.verified_steps : [];
  const verifiedHopCount = verifiedSteps.filter((s) => s.verified).length;
  const decision = data.decision || "Rejected";
  $("graph-kpis").innerHTML = [
    {
      label: t("kpi_decision"),
      val: decision,
      cls: data.ok ? "kpi-ok" : "kpi-danger",
      sub: t("kpi_verified_hops", { count: verifiedHopCount }),
    },
    {
      label: t("kpi_download_payload"),
      val: fmtBytes(data.total_download_bytes ?? 0),
      cls: "kpi-accent",
      sub: t("kpi_full_target", { size: fmtBytes(data.full_target_bytes ?? 0) }),
    },
    {
      label: t("kpi_bandwidth_saved"),
      val: fmtPct(data.savings_permille ?? 0),
      cls: (data.savings_permille ?? 0) > 0 ? "kpi-ok" : "",
      sub: t("kpi_saved_sub", { size: fmtBytes(data.savings_bytes ?? 0) }),
    },
    {
      label: t("kpi_catalog_sha"),
      val: shortHash(data.catalog_sha256, 12),
      cls: "",
      sub: t("kpi_channel", { channel: data.channel || "—" }),
    },
  ]
    .map(
      (k) => `<div class="kpi-box"><span class="kpi-label">${escapeHtml(k.label)}</span><span class="kpi-value ${k.cls}">${escapeHtml(k.val)}</span><span class="kpi-sub">${escapeHtml(k.sub)}</span></div>`
    )
    .join("");

  // Hop ledger
  if (verifiedSteps.length === 0) {
    $("graph-hops-table").innerHTML = `<p class="muted" style="margin:0;font-size:0.82rem;">${escapeHtml(t("graph_no_hops"))} <code>${escapeHtml(decision)}</code>.</p>`;
  } else {
    const rows = verifiedSteps
      .map(
        (s) => `<tr class="${s.verified ? "" : "row-danger"}">
          <td class="mono">#${s.step}</td>
          <td class="mono">v${s.from_version} → v${s.to_version}</td>
          <td class="mono">${fmtBytes(s.patch_bytes)}</td>
          <td class="mono">${escapeHtml(shortHash(s.patch_sha256, 12))}</td>
          <td class="mono">${escapeHtml(shortHash(s.restored_sha256, 12))}</td>
          <td><span class="pill ${s.verified ? "pill-ok" : "pill-danger"}">${escapeHtml(s.verified ? t("pill_sha_ok") : t("pill_rejected"))}</span></td>
        </tr>`
      )
      .join("");
    $("graph-hops-table").innerHTML = `<table>
      <thead><tr><th>${escapeHtml(t("th_hop"))}</th><th>${escapeHtml(t("th_transition"))}</th><th>${escapeHtml(t("th_patch_size"))}</th><th>${escapeHtml(t("th_patch_sha"))}</th><th>${escapeHtml(t("th_restored_sha"))}</th><th>${escapeHtml(t("th_status"))}</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
  }

  try {
    $("graph-catalog-preview").textContent = data.catalog_json_preview
      ? JSON.stringify(JSON.parse(data.catalog_json_preview), null, 2)
      : "";
  } catch {
    $("graph-catalog-preview").textContent = data.catalog_json_preview || "";
  }
}

/* ==================== TAB 2: BSDIFF40 X-RAY ==================== */

function setLimitInputs(preset) {
  const map = {
    generous: [131072, 1048576, 2097152, 16384],
    tight: [65536, 131072, 8192, 512],
    balanced: [131072, 262144, 262144, 4096],
  };
  const vals = map[preset] || map.generous;
  $("xray-max-patch").value = vals[0];
  $("xray-max-output").value = vals[1];
  $("xray-max-decomp").value = vals[2];
  $("xray-max-controls").value = vals[3];
}

function syncXrayLimitPresetChips(activePreset) {
  document.querySelectorAll("#xray-limit-presets .chip-btn").forEach((b) => {
    b.classList.toggle("active", activePreset !== null && b.dataset.limit === activePreset);
  });
}

function parseXrayLimitInputs() {
  const specs = [
    ["xray-max-patch", "max_patch_bytes"],
    ["xray-max-output", "max_output_bytes"],
    ["xray-max-decomp", "max_decompressed_bytes"],
    ["xray-max-controls", "max_control_instructions"],
  ];
  const parsed = [];
  for (const [id, field] of specs) {
    const raw = String($(id).value ?? "").trim();
    if (!/^[+-]?\d+$/.test(raw)) {
      return { ok: false, field, raw };
    }
    const num = Number(raw);
    if (!Number.isSafeInteger(num)) {
      return { ok: false, field, raw };
    }
    parsed.push(num);
  }
  return { ok: true, values: parsed };
}

function runXray(useCustomLimitNumbers = false) {
  if (!state.studio) return;
  let data;
  if (state.xray.mode === "custom") {
    if (state.xray.customHex === null) {
      if (state.xray.lastData) renderXray(state.xray.lastData);
      return;
    }
    const lim = parseXrayLimitInputs();
    if (!lim.ok) {
      data = {
        ok: false,
        preset_name: "custom_upload",
        limit_preset: "custom",
        error: {
          kind: "InvalidConfiguration",
          stage: "Configuration",
          field: lim.field,
          value: null,
          limit: null,
          raw: t("err_limit_not_int", { field: lim.field, value: lim.raw || "(empty)" }),
          raw_i18n: { key: "err_limit_not_int", vars: { field: lim.field, value: lim.raw || "(empty)" } },
        },
      };
    } else {
      data = JSON.parse(
        state.studio.studio_analyze_patch_hex(
          state.xray.customHex,
          lim.values[0],
          lim.values[1],
          lim.values[2],
          lim.values[3]
        )
      );
    }
  } else if (useCustomLimitNumbers && state.xray.lastPatchHex !== null) {
    const lim = parseXrayLimitInputs();
    if (!lim.ok) {
      data = {
        ok: false,
        preset_name: state.xray.preset,
        limit_preset: "custom",
        error: {
          kind: "InvalidConfiguration",
          stage: "Configuration",
          field: lim.field,
          value: null,
          limit: null,
          raw: t("err_limit_not_int", { field: lim.field, value: lim.raw || "(empty)" }),
          raw_i18n: { key: "err_limit_not_int", vars: { field: lim.field, value: lim.raw || "(empty)" } },
        },
      };
    } else {
      data = JSON.parse(
        state.studio.studio_analyze_patch_hex(
          state.xray.lastPatchHex,
          lim.values[0],
          lim.values[1],
          lim.values[2],
          lim.values[3]
        )
      );
    }
  } else {
    data = JSON.parse(
      state.studio.studio_analyze_patch_preset(state.xray.preset, state.xray.limitPreset)
    );
    if (typeof data.patch_hex === "string") {
      state.xray.lastPatchHex = data.patch_hex;
      state.xray.lastPatchName = `${state.xray.preset}.patch`;
    }
  }
  state.xray.lastData = data;
  renderXray(data);
}

function renderXray(data) {
  if (!data) return;
  const riskPill = $("xray-risk-pill");
  const errBox = $("xray-error-box");
  const content = $("xray-content");
  $("xray-download-patch").disabled = state.xray.lastPatchHex === null;

  if (!data.ok) {
    riskPill.className = "pill pill-danger";
    riskPill.textContent = t("xray_rejected_pill", { kind: data.error?.kind || "Error" });
    errBox.className = "verdict-banner blocked";
    const errVal = data.error?.value !== null && data.error?.value !== undefined
      ? `• ${escapeHtml(t("xray_value"))} <code>${escapeHtml(data.error.value)}</code>`
      : "";
    const errLim = data.error?.limit !== null && data.error?.limit !== undefined
      ? `• ${escapeHtml(t("xray_limit"))} <code>${escapeHtml(data.error.limit)}</code>`
      : "";
    const rawText = data.error?.raw_i18n
      ? t(data.error.raw_i18n.key, data.error.raw_i18n.vars)
      : (data.error?.raw || "");
    errBox.innerHTML = `
      <div class="verdict-head">
        <span class="pill pill-danger">${escapeHtml(t("xray_fail_closed"))}</span>
        <span class="verdict-code">${escapeHtml(data.error?.kind)} @ ${escapeHtml(data.error?.stage)}</span>
      </div>
      <p class="verdict-summary">
        ${escapeHtml(t("xray_field"))} <code>${escapeHtml(data.error?.field || "—")}</code>
        ${errVal}
        ${errLim}
      </p>
      <p class="verdict-raw">${escapeHtml(rawText)}</p>
    `;
    content.classList.add("hidden");
    return;
  }

  errBox.className = "verdict-banner hidden";
  content.classList.remove("hidden");

  const rCls = data.risk_level === "High" ? "pill-danger" : data.risk_level === "Elevated" ? "pill-warn" : "pill-ok";
  const rLabel = data.risk_level === "High"
    ? t("xray_risk_high")
    : data.risk_level === "Elevated"
    ? t("xray_risk_elevated")
    : t("xray_risk_low");
  riskPill.className = `pill ${rCls}`;
  riskPill.textContent = t("xray_risk_pill", { level: rLabel });

  const h = data.header;
  const s = data.streams;
  const r = data.ratios;
  const total = Math.max(h.patch_bytes, 1);
  const segs = [
    { cls: "seg-hdr", name: "HDR", bytes: h.header_bytes, range: `[0..32)`, color: "#818cf8" },
    { cls: "seg-ctrl", name: "CTRL", bytes: h.control_length, range: `[${h.control_start}..${h.diff_start})`, color: "#38bdf8" },
    { cls: "seg-diff", name: "DIFF", bytes: h.diff_length, range: `[${h.diff_start}..${h.extra_start})`, color: "#34d399" },
    { cls: "seg-extra", name: "EXTRA", bytes: h.extra_length, range: `[${h.extra_start}..${h.patch_bytes})`, color: "#fbbf24" },
  ];
  $("xray-wire-total").textContent = t("xray_wire_total", {
    patch: h.patch_bytes.toLocaleString(),
    output: h.new_bytes.toLocaleString(),
  });
  $("xray-segmented-bar").innerHTML = segs
    .map((sg) => {
      const pct = Math.max((sg.bytes / total) * 100, 6);
      return `<div class="xray-seg ${sg.cls}" style="flex:${pct}" title="${sg.name}: ${sg.bytes} B ${sg.range}">${sg.name} ${sg.bytes}B</div>`;
    })
    .join("");
  $("xray-legend").innerHTML = segs
    .map(
      (sg) => `<div class="legend-item"><span class="legend-dot" style="background:${sg.color}"></span><div><strong class="mono">${sg.name}</strong> <span class="mono">${sg.bytes} B</span><div class="mono muted" style="font-size:0.7rem">${sg.range}</div></div></div>`
    )
    .join("");

  $("xray-kpis").innerHTML = [
    {
      label: t("kpi_expansion_ratio"),
      val: `${(r.expansion_ratio_permille / 1000).toFixed(2)}×`,
      cls: r.expansion_ratio_permille >= 100000 ? "kpi-danger" : r.expansion_ratio_permille >= 20000 ? "kpi-warn" : "kpi-ok",
      sub: `${s.expanded_bytes.toLocaleString()} B / ${s.total_compressed_bytes.toLocaleString()} B`,
    },
    {
      label: t("kpi_patch_output"),
      val: fmtPct(r.patch_to_output_permille),
      cls: r.patch_to_output_permille >= 1000 ? "kpi-warn" : "kpi-ok",
      sub: `${h.patch_bytes.toLocaleString()} B vs ${h.new_bytes.toLocaleString()} B`,
    },
    {
      label: t("kpi_diff_extra_share"),
      val: `${fmtPct(r.diff_share_permille)} / ${fmtPct(r.extra_share_permille)}`,
      cls: r.extra_share_permille >= 850 ? "kpi-warn" : "kpi-accent",
      sub: t("kpi_diff_extra_sub", { diff: s.diff_bytes.toLocaleString(), extra: s.extra_bytes.toLocaleString() }),
    },
    {
      label: t("kpi_controls_seeks"),
      val: `${s.control_count} / ${data.seeks.negative_seek_count}`,
      cls: data.seeks.negative_seek_count > 0 ? "kpi-accent" : "",
      sub: t("kpi_max_abs_seek", { val: data.seeks.max_abs_seek_str }),
    },
  ]
    .map(
      (k) => `<div class="kpi-box"><span class="kpi-label">${escapeHtml(k.label)}</span><span class="kpi-value ${k.cls}">${escapeHtml(k.val)}</span><span class="kpi-sub">${escapeHtml(k.sub)}</span></div>`
    )
    .join("");

  if (data.risk_flags.length === 0) {
    $("xray-flags-list").innerHTML = `<div class="flag-item"><span class="pill pill-ok">${escapeHtml(t("xray_clean_pill"))}</span><span class="muted">${escapeHtml(t("xray_clean_desc"))}</span></div>`;
  } else {
    $("xray-flags-list").innerHTML = data.risk_flags
      .map((f) => {
        const fc = f.severity === "High" ? "high" : "elevated";
        const pc = f.severity === "High" ? "pill-danger" : "pill-warn";
        return `<div class="flag-item ${fc}"><span class="pill ${pc} mono">${escapeHtml(f.code)}</span><span>${escapeHtml(f.detail)}</span></div>`;
      })
      .join("");
  }

  $("xray-seek-summary").textContent = t("xray_showing_controls", {
    shown: data.sample_controls.length,
    total: s.control_count,
  });
  const maxTuple = Math.max(
    1,
    ...data.sample_controls.map((c) => c.add_bytes + c.extra_bytes)
  );
  const ctrlRows = data.sample_controls
    .slice(0, 32)
    .map((c) => {
      const addPct = Math.round((c.add_bytes / maxTuple) * 100);
      const extPct = Math.round((c.extra_bytes / maxTuple) * 100);
      const seekCls = c.seek_offset < 0 ? "pill-warn" : "pill-info";
      return `<tr>
        <td class="mono">#${c.index}</td>
        <td class="mono">${c.add_bytes.toLocaleString()} B</td>
        <td class="mono">${c.extra_bytes.toLocaleString()} B</td>
        <td>
          <div style="display:flex;gap:2px;width:130px;height:10px;background:#091020;border-radius:4px;overflow:hidden;border:1px solid var(--border)">
            <div style="width:${addPct}%;background:#34d399"></div>
            <div style="width:${extPct}%;background:#fbbf24"></div>
          </div>
        </td>
        <td class="mono"><span class="pill ${seekCls}" style="padding:1px 7px;font-size:0.72rem">${c.seek_offset >= 0 ? "+" : ""}${escapeHtml(c.seek_offset_str)}</span></td>
      </tr>`;
    })
    .join("");
  $("xray-controls-table").innerHTML = `<table>
    <thead><tr><th>${escapeHtml(t("th_idx"))}</th><th>${escapeHtml(t("th_add_diff"))}</th><th>${escapeHtml(t("th_extra"))}</th><th>${escapeHtml(t("th_mix"))}</th><th>${escapeHtml(t("th_seek_offset"))}</th></tr></thead>
    <tbody>${ctrlRows}</tbody>
  </table>`;

  $("xray-mbt-code").textContent = data.moonbit_snippet;
  $("xray-cli-code").textContent = data.cli_flags;
}

/* ==================== TAB 3: 4 KiB STREAM OSCILLOSCOPE ==================== */

function stopStreamPlayback() {
  if (state.stream.timer) {
    clearInterval(state.stream.timer);
    state.stream.timer = null;
  }
  $("stream-play").textContent = t("btn_play");
}

function updateStreamAbortLabel() {
  $("stream-abort-val").textContent =
    state.stream.abortAfter === 0
      ? t("stream_abort_complete")
      : t("stream_abort_after", { n: state.stream.abortAfter });
}

function runStream() {
  if (!state.studio) return;
  stopStreamPlayback();
  const preset = $("stream-preset").value;
  state.stream.preset = preset;
  state.stream.abortAfter = Number($("stream-abort").value);

  let fullChunks = state.stream.presetChunkCounts[preset];
  if (fullChunks === undefined && state.stream.abortAfter > 0) {
    const probe = JSON.parse(state.studio.studio_trace_stream_apply(preset, 0));
    if (probe.ok) {
      fullChunks = (probe.chunks || []).length;
      state.stream.presetChunkCounts[preset] = fullChunks;
    }
  }
  if (fullChunks !== undefined) {
    $("stream-abort").max = String(fullChunks);
    if (state.stream.abortAfter > fullChunks) {
      state.stream.abortAfter = fullChunks;
      $("stream-abort").value = String(fullChunks);
    }
  }
  updateStreamAbortLabel();

  const data = JSON.parse(
    state.studio.studio_trace_stream_apply(preset, state.stream.abortAfter)
  );
  if (state.stream.abortAfter === 0 && data.ok) {
    const total = (data.chunks || []).length;
    state.stream.presetChunkCounts[preset] = total;
    $("stream-abort").max = String(total);
  }
  state.stream.data = data;
  const maxCursor = (data.chunks || []).length;
  state.stream.cursor = maxCursor;
  $("stream-cursor").max = String(maxCursor);
  $("stream-cursor").value = String(maxCursor);
  renderStreamFrame();
}

function renderStreamFrame() {
  updateStreamAbortLabel();
  const data = state.stream.data;
  if (!data) return;
  const chunks = Array.isArray(data.chunks) ? data.chunks : [];
  const events = Array.isArray(data.events) ? data.events : [];
  const counters = data.counters || {
    read_old_calls: 0,
    read_patch_calls: 0,
    checkpoint_calls: 0,
  };
  const cur = state.stream.cursor;
  const totalChunks = chunks.length;
  $("stream-cursor-val").textContent = `${cur} / ${totalChunks}`;

  const pill = $("stream-status-pill");
  if (data.ok) {
    pill.className = "pill pill-ok";
    pill.textContent = t("stream_pill_verified");
  } else if (data.aborted) {
    pill.className = "pill pill-danger";
    pill.textContent = t("stream_pill_cancelled");
  } else {
    pill.className = "pill pill-danger";
    pill.textContent = t("stream_pill_error", { kind: data.error?.error_type || "Failed" });
  }

  // Stage pipeline
  const stageNames = new Set((data.stages || []).map((s) => s.stage));
  const stagesUi = [
    { name: t("stage_hdr_name"), done: stageNames.has("HeaderVerified"), aborted: false, sub: t("stage_hdr_sub") },
    { name: t("stage_restore_name"), done: stageNames.has("Restoring"), aborted: false, sub: t("stage_restore_sub") },
    { name: t("stage_validate_name"), done: stageNames.has("Validating"), aborted: data.aborted && !stageNames.has("Validating"), sub: t("stage_validate_sub") },
    {
      name: data.aborted ? t("stage_aborted_name") : t("stage_verified_name"),
      done: data.sha256_verified,
      aborted: !data.ok,
      sub: data.final_delivered ? t("stage_delivered_sub") : t("stage_uncommitted_sub"),
    },
  ];
  $("stream-pipeline").innerHTML = stagesUi
    .map(
      (st) => `<div class="stage-node ${st.aborted ? "aborted" : st.done ? "done" : ""}"><strong>${escapeHtml(st.name)}</strong><small class="muted">${escapeHtml(st.sub)}</small></div>`
    )
    .join("");

  // Verdict
  $("stream-verdict").className = `verdict-banner ${data.ok ? "verified" : "blocked"}`;
  $("stream-verdict").innerHTML = data.ok
    ? `<div class="verdict-head"><span class="pill pill-ok">${escapeHtml(t("stream_verdict_ok_pill"))}</span><span class="verdict-code">SHA-256 ${escapeHtml(shortHash(data.restored_sha256, 20))}</span></div>
       <p class="verdict-summary">${escapeHtml(t("stream_verdict_ok_summary", { chunks: totalChunks, peak: data.max_chunk_bytes }))}</p>`
    : data.aborted
    ? `<div class="verdict-head"><span class="pill pill-danger">${escapeHtml(t("stream_verdict_abort_pill"))}</span><span class="verdict-code">StreamApplyError::${escapeHtml(data.error?.error_type)}("${escapeHtml(data.error?.detail)}")</span></div>
       <p class="verdict-summary">${escapeHtml(t("stream_verdict_abort_summary", { chunks: totalChunks, written: fmtBytes(data.written_bytes) }))}</p>`
    : `<div class="verdict-head"><span class="pill pill-danger">${escapeHtml(t("stream_verdict_err_pill"))}</span><span class="verdict-code">${escapeHtml(data.error?.error_type || "Error")}</span></div>
       <p class="verdict-summary">${escapeHtml(t("stream_verdict_err_summary", { detail: data.error?.detail || "" }))}</p>`;

  // Live counters at current scrubber position
  const activeChunk = cur > 0 ? chunks[cur - 1] : null;
  const shownWritten = activeChunk ? activeChunk.cumulative_bytes : 0;
  const shownOldReads = activeChunk ? activeChunk.old_reads_so_far : 0;
  const shownPatchReads = activeChunk ? activeChunk.patch_reads_so_far : 0;
  $("stream-counters").innerHTML = [
    [t("cnt_write_chunks"), `${cur} / ${totalChunks}`],
    [t("cnt_bytes_emitted"), fmtCompactBytes(shownWritten)],
    [t("cnt_read_old"), t("cnt_total_paren", { shown: shownOldReads, total: counters.read_old_calls })],
    [t("cnt_read_patch"), t("cnt_total_paren", { shown: shownPatchReads, total: counters.read_patch_calls })],
    [t("cnt_peak_chunk"), `${data.max_chunk_bytes} B ≤ 4096 B`],
    [t("cnt_checkpoints"), `${counters.checkpoint_calls}`],
  ]
    .map(([l, v]) => `<div class="counter-tile"><small>${escapeHtml(l)}</small><strong>${escapeHtml(v)}</strong></div>`)
    .join("");

  // SVG Oscilloscope waveform
  const W = 760;
  const H = 220;
  const padL = 56;
  const padR = 24;
  const padT = 26;
  const padB = 34;
  const plotW = W - padL - padR;
  const plotH = H - padT - padB;
  const ceilingY = padT + 14;
  const maxVal = 4600;
  const yOf = (val) => padT + plotH - (val / maxVal) * plotH;
  const slots = Math.max(totalChunks + (data.aborted ? 1 : 0), 5);
  const slotW = plotW / slots;

  const svg = [
    `<line x1="${padL}" y1="${padT + plotH}" x2="${W - padR}" y2="${padT + plotH}" stroke="#334155" stroke-width="1.5"/>`,
    `<line x1="${padL}" y1="${yOf(4096)}" x2="${W - padR}" y2="${yOf(4096)}" stroke="#fb7185" stroke-width="1.5" stroke-dasharray="6 4"/>`,
    `<text x="${padL + 6}" y="${yOf(4096) - 6}" fill="#fda4af" font-family="monospace" font-size="10.5" font-weight="700">${escapeHtml(t("svg_stream_ceiling"))}</text>`,
    `<text x="${padL - 8}" y="${yOf(4096) + 4}" text-anchor="end" fill="#94a3b8" font-family="monospace" font-size="10">4096</text>`,
    `<text x="${padL - 8}" y="${yOf(2048) + 4}" text-anchor="end" fill="#64748b" font-family="monospace" font-size="10">2048</text>`,
    `<text x="${padL - 8}" y="${yOf(0) + 4}" text-anchor="end" fill="#64748b" font-family="monospace" font-size="10">0 B</text>`,
  ];

  chunks.forEach((ch, idx) => {
    const x = padL + idx * slotW + 10;
    const bw = Math.max(slotW - 20, 18);
    const top = yOf(ch.length);
    const bh = padT + plotH - top;
    const active = idx < cur;
    const isCurrent = idx === cur - 1;
    const fill = isCurrent ? "#38bdf8" : active ? "#34d399" : "#1e293b";
    svg.push(
      `<rect x="${x}" y="${top}" width="${bw}" height="${bh}" rx="6" fill="${fill}" opacity="${active ? "0.92" : "0.45"}"/>` +
      `<text x="${x + bw / 2}" y="${top - 6}" text-anchor="middle" fill="${active ? "#e2e8f0" : "#64748b"}" font-family="monospace" font-size="10">${ch.length}B</text>` +
      `<text x="${x + bw / 2}" y="${H - 12}" text-anchor="middle" fill="#94a3b8" font-family="monospace" font-size="10">#${ch.chunk_index}</text>`
    );
  });

  if (data.aborted) {
    const ax = padL + totalChunks * slotW + 10;
    const bw = Math.max(slotW - 20, 18);
    svg.push(
      `<rect x="${ax}" y="${ceilingY}" width="${bw}" height="${padT + plotH - ceilingY}" rx="6" fill="rgba(244,63,94,0.16)" stroke="#fb7185" stroke-dasharray="4 3"/>` +
      `<text x="${ax + bw / 2}" y="${padT + plotH / 2}" text-anchor="middle" fill="#fda4af" font-family="monospace" font-size="11" font-weight="700">${escapeHtml(t("svg_stream_aborted"))}</text>`
    );
  }
  $("stream-svg").innerHTML = svg.join("");

  $("stream-kpis").innerHTML = [
    { label: t("kpi_old_patch_target"), val: `${fmtCompactBytes(data.old_bytes)} / ${fmtCompactBytes(data.patch_bytes)} / ${fmtCompactBytes(data.target_bytes)}`, cls: "", sub: t("kpi_real_diff") },
    { label: t("kpi_peak_chunk"), val: `${data.max_chunk_bytes} B`, cls: "kpi-ok", sub: t("kpi_ceiling_4096") },
    { label: t("kpi_target_sha"), val: shortHash(data.target_sha256, 12), cls: "kpi-accent", sub: data.sha256_verified ? t("kpi_exact_match") : t("kpi_not_committed") },
    { label: t("kpi_delivery_state"), val: data.final_delivered ? t("kpi_committed") : t("kpi_discarded"), cls: data.final_delivered ? "kpi-ok" : "kpi-danger", sub: data.ok ? t("kpi_verified") : data.aborted ? t("kpi_fail_closed_io") : t("kpi_rejected") },
  ]
    .map(
      (k) => `<div class="kpi-box"><span class="kpi-label">${escapeHtml(k.label)}</span><span class="kpi-value ${k.cls}">${escapeHtml(k.val)}</span><span class="kpi-sub">${escapeHtml(k.sub)}</span></div>`
    )
    .join("");

  // Event trace table
  const maxEvIdx = activeChunk ? activeChunk.event_index : -1;
  $("stream-event-count").textContent = t("stream_events_recorded", { count: events.length });
  const evRows = events
    .map((ev) => {
      const cls =
        ev.kind === "checkpoint_abort"
          ? "row-danger"
          : ev.index === maxEvIdx
          ? "row-active"
          : "";
      return `<tr class="${cls}">
        <td class="mono">${ev.index}</td>
        <td class="mono">${escapeHtml(ev.kind)}</td>
        <td class="mono">${escapeHtml(ev.detail)}</td>
        <td class="mono">${ev.offset !== null ? ev.offset : "—"}</td>
        <td class="mono">${ev.cumulative_written.toLocaleString()} B</td>
      </tr>`;
    })
    .join("");
  $("stream-events-table").innerHTML = `<table>
    <thead><tr><th>#</th><th>${escapeHtml(t("th_callback"))}</th><th>${escapeHtml(t("th_detail"))}</th><th>${escapeHtml(t("th_offset"))}</th><th>${escapeHtml(t("th_written"))}</th></tr></thead>
    <tbody>${evRows}</tbody>
  </table>`;
}

/* ==================== TAB 4: DIRECTORY DELTA EXPLORER ==================== */

async function readDirectoryFiles(fileList) {
  const files = Array.from(fileList || []);
  if (files.length > DIR_MAX_FILES) {
    const err = new Error(t("dir_err_too_many_files", { count: files.length, limit: DIR_MAX_FILES }));
    err.i18nKey = "dir_err_too_many_files";
    err.vars = { count: files.length, limit: DIR_MAX_FILES };
    throw err;
  }
  let totalBytes = 0;
  for (const f of files) {
    if (f.size > DIR_MAX_FILE_BYTES) {
      const displayPath = f.webkitRelativePath || f.name;
      const err = new Error(t("dir_err_file_too_large", { path: displayPath }));
      err.i18nKey = "dir_err_file_too_large";
      err.vars = { path: displayPath };
      throw err;
    }
    totalBytes += f.size;
    if (totalBytes > DIR_MAX_TOTAL_BYTES) {
      const err = new Error(t("dir_err_total_too_large", { size: fmtCompactBytes(totalBytes) }));
      err.i18nKey = "dir_err_total_too_large";
      err.vars = { size: fmtCompactBytes(totalBytes) };
      throw err;
    }
  }
  const out = [];
  for (const f of files) {
    const rawPath = (f.webkitRelativePath || f.name).replace(/\\/g, "/");
    const parts = rawPath.split("/");
    const rel = parts.length > 1 ? parts.slice(1).join("/") : rawPath;
    const buf = new Uint8Array(await f.arrayBuffer());
    out.push({ path: rel, data_hex: bytesToHex(buf) });
  }
  return { files: out, totalBytes };
}

function runDirDelta() {
  if (!state.studio) return;
  const req = {
    tamper_mode: state.dir.tamper,
  };
  if (state.dir.mode === "custom" && state.dir.customOld && state.dir.customNew) {
    req.old_files = state.dir.customOld;
    req.new_files = state.dir.customNew;
  } else {
    req.preset = "mini_app_v1_to_v2";
  }
  const data = JSON.parse(state.studio.studio_run_dir_delta(JSON.stringify(req)));
  state.dir.lastData = data;
  renderDirDelta(data);
}

function renderDirDelta(data) {
  if (!data) return;
  $("dir-signer-badge").textContent = t("dir_signer_prefix", { kid: data.signer_key_id || "—" });
  const v = data.security_verdict || {
    status: "BLOCKED",
    error_type: "InvalidRequest",
    detail: "",
    raw_error: "",
  };
  $("dir-verdict").className = `verdict-banner ${data.ok ? "verified" : "blocked"}`;
  $("dir-verdict").innerHTML = `
    <div class="verdict-head">
      <span class="pill ${data.ok ? "pill-ok" : "pill-danger"}">${escapeHtml(v.status)}</span>
      <span class="verdict-code">${escapeHtml(v.error_type)}</span>
    </div>
    <p class="verdict-summary">${escapeHtml(v.detail)}</p>
    ${v.raw_error ? `<p class="verdict-raw">${escapeHtml(v.raw_error)}</p>` : ""}
  `;

  $("dir-tree-hashes").innerHTML = [
    [t("dir_hash_old"), data.old_tree_sha256 || "—"],
    [t("dir_hash_new_manifest"), data.new_tree_sha256 || "—"],
    [t("dir_hash_restored"), data.restored_tree_sha256 || (data.ok ? "—" : t("dir_hash_aborted"))],
  ]
    .map(([l, h]) => `<div class="hash-row"><small>${escapeHtml(l)}</small><code>${escapeHtml(h)}</code></div>`)
    .join("");

  const s = data.summary;
  if (s) {
    const pureAdded = Math.max(0, s.added_count - s.full_fallback_count);
    $("dir-kpis").innerHTML = [
      { label: t("kpi_transfer_delta"), val: fmtBytes(s.delta_payload_bytes), cls: "kpi-accent", sub: t("kpi_vs_full", { size: fmtBytes(s.new_total_bytes) }) },
      { label: t("kpi_total_savings"), val: fmtPct(s.savings_permille), cls: "kpi-ok", sub: t("kpi_avoided", { size: fmtBytes(s.savings_bytes) }) },
      { label: t("kpi_zero_byte_moves"), val: t("kpi_eq_ren", { unchanged: s.unchanged_count, renamed: s.renamed_count }), cls: "kpi-ok", sub: t("kpi_zero_transferred") },
      { label: t("kpi_patched_fallback"), val: `${s.patched_count} / ${s.full_fallback_count}`, cls: "kpi-warn", sub: t("kpi_added_del", { added: pureAdded, deleted: s.deleted_count }) },
    ]
      .map(
        (k) => `<div class="kpi-box"><span class="kpi-label">${escapeHtml(k.label)}</span><span class="kpi-value ${k.cls}">${escapeHtml(k.val)}</span><span class="kpi-sub">${escapeHtml(k.sub)}</span></div>`
      )
      .join("");
  } else {
    $("dir-kpis").innerHTML = "";
  }

  renderDirTable();

  try {
    $("dir-manifest-preview").textContent = data.manifest_json_preview
      ? JSON.stringify(JSON.parse(data.manifest_json_preview), null, 2)
      : "";
  } catch {
    $("dir-manifest-preview").textContent = data.manifest_json_preview || "";
  }
}

function renderDirTable() {
  const data = state.dir.lastData;
  if (!data || !Array.isArray(data.entries) || data.entries.length === 0) {
    $("dir-entries-table").innerHTML = `<p class="muted" style="margin:0;font-size:0.82rem;">${escapeHtml(t("dir_table_empty"))}</p>`;
    return;
  }
  const flt = state.dir.filter;
  const list = data.entries.filter((e) => flt === "ALL" || e.action === flt);
  if (list.length === 0) {
    $("dir-entries-table").innerHTML = `<p class="muted" style="margin:0;font-size:0.82rem;">${escapeHtml(t("dir_table_filtered_empty", { filter: flt }))}</p>`;
    return;
  }
  const tamperedBlobs = new Set((data.blobs || []).filter((b) => b.tampered).map((b) => b.name));

  const rows = list
    .map((e) => {
      const pathDisp =
        e.action === "RENAMED"
          ? `<span class="muted">${escapeHtml(e.from_path)} →</span> ${escapeHtml(e.path)}`
          : escapeHtml(e.path);
      const isTamp = e.blob_name && tamperedBlobs.has(e.blob_name);
      const savedPct = Math.round(e.savings_permille / 10);
      return `<tr class="${isTamp ? "row-danger" : ""}">
        <td><span class="act-pill act-${escapeHtml(e.action)}">${escapeHtml(e.action)}</span></td>
        <td class="mono">${pathDisp}</td>
        <td class="mono">${fmtCompactBytes(e.old_bytes)}</td>
        <td class="mono">${fmtCompactBytes(e.new_bytes)}</td>
        <td class="mono">${fmtCompactBytes(e.payload_bytes)}${isTamp ? ` <span class="pill pill-danger" style="padding:1px 6px;font-size:0.68rem">${escapeHtml(t("pill_tampered"))}</span>` : ""}</td>
        <td>
          <div style="display:flex;align-items:center;gap:6px">
            <div class="mini-bar-wrap"><div class="mini-bar" style="width:${savedPct}%;background:${savedPct > 0 ? "#34d399" : "#475569"}"></div></div>
            <span class="mono">${fmtPct(e.savings_permille)}</span>
          </div>
        </td>
        <td class="mono muted">${escapeHtml(e.blob_name || "—")}</td>
      </tr>`;
    })
    .join("");
  $("dir-entries-table").innerHTML = `<table>
    <thead><tr><th>${escapeHtml(t("th_action"))}</th><th>${escapeHtml(t("th_rel_path"))}</th><th>${escapeHtml(t("th_old"))}</th><th>${escapeHtml(t("th_new"))}</th><th>${escapeHtml(t("th_payload"))}</th><th>${escapeHtml(t("th_saved"))}</th><th>${escapeHtml(t("th_blob"))}</th></tr></thead>
    <tbody>${rows}</tbody>
  </table>`;
}

/* ==================== EVENT WIRING & BOOTSTRAP ==================== */

function bindEvents() {
  // Tabs
  document.querySelectorAll(".tab-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      const target = btn.dataset.tab;
      if (target !== "stream") {
        stopStreamPlayback();
      }
      document.querySelectorAll(".tab-btn").forEach((b) => {
        const active = b.dataset.tab === target;
        b.classList.toggle("active", active);
        b.setAttribute("aria-selected", String(active));
      });
      document.querySelectorAll(".tab-panel").forEach((p) => {
        p.classList.toggle("active", p.id === `panel-${target}`);
      });
    });
  });

  // Language toggle — translate static + dynamic UI across ALL 4 tabs without resetting custom uploads
  $("lang-toggle").addEventListener("click", () => {
    state.lang = state.lang === "en" ? "zh" : "en";
    applyLanguage();
    if (state.graph.lastData) renderGraph(state.graph.lastData);
    if (state.xray.lastData) renderXray(state.xray.lastData);
    if (state.stream.data) renderStreamFrame();
    if (state.dir.lastData) renderDirDelta(state.dir.lastData);
  });

  // Tab 1: Graph controls (bind single event per control; allow clearing #graph-min-catalog mid-edit)
  ["graph-current", "graph-target", "graph-budget-enabled", "graph-allow-full"].forEach((id) => {
    $(id).addEventListener("change", runGraph);
  });
  ["graph-max-steps", "graph-budget"].forEach((id) => {
    $(id).addEventListener("input", runGraph);
  });
  $("graph-min-catalog").addEventListener("input", () => {
    const trimmed = String($("graph-min-catalog").value ?? "").trim();
    if (!/^[+-]?\d+$/.test(trimmed)) return;
    runGraph();
  });
  $("graph-min-catalog").addEventListener("change", () => {
    const normalized = parseStrictIntOrFallback($("graph-min-catalog").value, 1);
    $("graph-min-catalog").value = String(normalized);
    runGraph();
  });
  $("graph-attack-buttons").addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-attack]");
    if (!btn) return;
    const prevAttack = state.graph.attack_mode;
    const nextAttack = btn.dataset.attack;
    state.graph.attack_mode = nextAttack;
    if (prevAttack === "downgrade_v1" && nextAttack !== "downgrade_v1") {
      if (Number($("graph-current").value) >= Number($("graph-target").value)) {
        $("graph-current").value = "1";
        $("graph-target").value = "4";
      }
    }
    document.querySelectorAll("#graph-attack-buttons .attack-btn").forEach((b) => {
      b.classList.toggle("active", b === btn);
    });
    runGraph();
  });

  // Tab 2: X-Ray presets, limits, drag & drop
  $("xray-presets").addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-preset]");
    if (!btn) return;
    state.xray.uploadSeq += 1;
    state.xray.mode = "preset";
    state.xray.preset = btn.dataset.preset;
    state.xray.customHex = null;
    setLimitInputs(state.xray.limitPreset);
    syncXrayLimitPresetChips(state.xray.limitPreset);
    document.querySelectorAll("#xray-presets .preset-btn").forEach((b) => {
      b.classList.toggle("active", b === btn);
    });
    runXray(false);
  });

  $("xray-limit-presets").addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-limit]");
    if (!btn) return;
    state.xray.limitPreset = btn.dataset.limit;
    setLimitInputs(state.xray.limitPreset);
    syncXrayLimitPresetChips(state.xray.limitPreset);
    runXray(state.xray.mode === "custom");
  });

  $("xray-apply-custom-limits").addEventListener("click", () => {
    syncXrayLimitPresetChips(null);
    runXray(true);
  });

  $("xray-download-patch").addEventListener("click", () => {
    if (state.xray.lastPatchHex === null) return;
    const blob = new Blob([hexToBytes(state.xray.lastPatchHex)], { type: "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = state.xray.lastPatchName || "sample.patch";
    a.click();
    URL.revokeObjectURL(url);
  });

  const handlePatchFile = async (file) => {
    if (!file) return;
    const seq = ++state.xray.uploadSeq;
    document.querySelectorAll("#xray-presets .preset-btn").forEach((b) => b.classList.remove("active"));
    if (file.size > MAX_PATCH_UPLOAD_BYTES) {
      state.xray.mode = "custom";
      state.xray.customHex = null;
      state.xray.lastPatchHex = null;
      state.xray.lastPatchName = file.name;
      const errData = {
        ok: false,
        preset_name: "custom_upload",
        limit_preset: "custom",
        error: {
          kind: "ResourceLimitExceeded",
          stage: "Configuration",
          field: "patch_file",
          value: file.size,
          limit: MAX_PATCH_UPLOAD_BYTES,
          raw: t("err_patch_too_large", {
            name: file.name,
            size: file.size.toLocaleString(),
            limit: MAX_PATCH_UPLOAD_BYTES.toLocaleString(),
          }),
          raw_i18n: {
            key: "err_patch_too_large",
            vars: {
              name: file.name,
              size: file.size.toLocaleString(),
              limit: MAX_PATCH_UPLOAD_BYTES.toLocaleString(),
            },
          },
        },
      };
      state.xray.lastData = errData;
      renderXray(errData);
      return;
    }
    const buf = new Uint8Array(await file.arrayBuffer());
    if (seq !== state.xray.uploadSeq) return;
    const hex = bytesToHex(buf);
    state.xray.mode = "custom";
    state.xray.customHex = hex;
    state.xray.lastPatchHex = hex;
    state.xray.lastPatchName = file.name;
    runXray(true);
  };

  $("xray-browse-btn").addEventListener("click", () => $("xray-file-input").click());
  $("xray-file-input").addEventListener("change", (ev) => {
    const file = ev.target.files?.[0];
    ev.target.value = "";
    handlePatchFile(file);
  });
  const dz = $("xray-dropzone");
  dz.addEventListener("dragover", (ev) => {
    ev.preventDefault();
    dz.classList.add("dragover");
  });
  dz.addEventListener("dragleave", () => dz.classList.remove("dragover"));
  dz.addEventListener("drop", (ev) => {
    ev.preventDefault();
    dz.classList.remove("dragover");
    handlePatchFile(ev.dataTransfer?.files?.[0]);
  });

  const copyTimers = new WeakMap();
  document.querySelectorAll(".copy-btn").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const target = $(btn.dataset.copyTarget);
      if (!target) return;
      try {
        await navigator.clipboard.writeText(target.textContent);
        const prevTimer = copyTimers.get(btn);
        if (prevTimer) clearTimeout(prevTimer);
        btn.textContent = t("btn_copied");
        const timer = setTimeout(() => {
          copyTimers.delete(btn);
          btn.textContent = t("btn_copy");
        }, 1200);
        copyTimers.set(btn, timer);
      } catch {
        // Ignore clipboard denial in restricted contexts.
      }
    });
  });

  // Tab 3: Stream oscilloscope
  $("stream-preset").addEventListener("change", runStream);
  $("stream-abort").addEventListener("input", runStream);
  $("stream-cursor").addEventListener("input", (ev) => {
    stopStreamPlayback();
    state.stream.cursor = Number(ev.target.value);
    renderStreamFrame();
  });
  $("stream-step-back").addEventListener("click", () => {
    stopStreamPlayback();
    state.stream.cursor = Math.max(0, state.stream.cursor - 1);
    $("stream-cursor").value = String(state.stream.cursor);
    renderStreamFrame();
  });
  $("stream-step-fwd").addEventListener("click", () => {
    stopStreamPlayback();
    const max = state.stream.data ? (state.stream.data.chunks || []).length : 0;
    state.stream.cursor = Math.min(max, state.stream.cursor + 1);
    $("stream-cursor").value = String(state.stream.cursor);
    renderStreamFrame();
  });
  $("stream-reset").addEventListener("click", () => {
    stopStreamPlayback();
    state.stream.cursor = 0;
    $("stream-cursor").value = "0";
    renderStreamFrame();
  });
  $("stream-play").addEventListener("click", () => {
    if (state.stream.timer) {
      stopStreamPlayback();
      return;
    }
    const max = state.stream.data ? (state.stream.data.chunks || []).length : 0;
    if (max <= 0) return;
    if (state.stream.cursor >= max) {
      state.stream.cursor = 0;
      $("stream-cursor").value = "0";
      renderStreamFrame();
    }
    $("stream-play").textContent = t("btn_pause");
    state.stream.timer = setInterval(() => {
      if (state.stream.cursor >= max) {
        stopStreamPlayback();
        return;
      }
      state.stream.cursor += 1;
      $("stream-cursor").value = String(state.stream.cursor);
      renderStreamFrame();
    }, 520);
  });

  // Tab 4: Directory delta
  const updateFolderReady = () => {
    $("dir-run-custom").disabled = !(state.dir.customOld && state.dir.customNew);
  };

  $("dir-use-preset").addEventListener("click", () => {
    state.dir.oldSeq += 1;
    state.dir.newSeq += 1;
    state.dir.mode = "preset";
    state.dir.customOld = null;
    state.dir.customNew = null;
    state.dir.oldStatus = { kind: "preset" };
    state.dir.newStatus = { kind: "preset" };
    $("dir-old-input").value = "";
    $("dir-new-input").value = "";
    updateFolderReady();
    renderDirPickerStatus();
    runDirDelta();
  });

  $("dir-old-input").addEventListener("change", async (ev) => {
    const files = Array.from(ev.target.files || []);
    ev.target.value = "";
    const seq = ++state.dir.oldSeq;
    try {
      const loaded = await readDirectoryFiles(files);
      if (seq !== state.dir.oldSeq) return;
      state.dir.customOld = loaded.files;
      state.dir.oldStatus = { kind: "loaded", count: loaded.files.length, totalBytes: loaded.totalBytes };
      updateFolderReady();
      renderDirPickerStatus();
    } catch (err) {
      if (seq !== state.dir.oldSeq) return;
      state.dir.customOld = null;
      state.dir.oldStatus = { kind: "error", message: err.message, i18nKey: err.i18nKey, vars: err.vars };
      updateFolderReady();
      renderDirPickerStatus();
    }
  });
  $("dir-new-input").addEventListener("change", async (ev) => {
    const files = Array.from(ev.target.files || []);
    ev.target.value = "";
    const seq = ++state.dir.newSeq;
    try {
      const loaded = await readDirectoryFiles(files);
      if (seq !== state.dir.newSeq) return;
      state.dir.customNew = loaded.files;
      state.dir.newStatus = { kind: "loaded", count: loaded.files.length, totalBytes: loaded.totalBytes };
      updateFolderReady();
      renderDirPickerStatus();
    } catch (err) {
      if (seq !== state.dir.newSeq) return;
      state.dir.customNew = null;
      state.dir.newStatus = { kind: "error", message: err.message, i18nKey: err.i18nKey, vars: err.vars };
      updateFolderReady();
      renderDirPickerStatus();
    }
  });
  $("dir-run-custom").addEventListener("click", () => {
    if (!state.dir.customOld || !state.dir.customNew) return;
    state.dir.mode = "custom";
    runDirDelta();
  });

  $("dir-tamper-buttons").addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-tamper]");
    if (!btn) return;
    state.dir.tamper = btn.dataset.tamper;
    document.querySelectorAll("#dir-tamper-buttons .attack-btn").forEach((b) => {
      b.classList.toggle("active", b === btn);
    });
    runDirDelta();
  });

  $("dir-action-filters").addEventListener("click", (ev) => {
    const btn = ev.target.closest("[data-filter]");
    if (!btn) return;
    state.dir.filter = btn.dataset.filter;
    document.querySelectorAll("#dir-action-filters .chip-btn").forEach((b) => {
      b.classList.toggle("active", b === btn);
    });
    renderDirTable();
  });
}

async function boot() {
  applyLanguage();
  bindEvents();
  try {
    const mod = await import("./dist/studio.js");
    state.studio = mod;
    state.studioInfo = JSON.parse(mod.studio_version());
    state.bootError = null;
    renderEngineBadge();
    renderBootBanner();
    runGraph();
    runXray(false);
    runStream();
    runDirDelta();
  } catch (err) {
    state.studioInfo = null;
    state.bootError = err?.message || String(err);
    renderEngineBadge();
    renderBootBanner();
  }
}

boot();
