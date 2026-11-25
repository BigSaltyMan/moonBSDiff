"""End-to-end build and Node.js ESM verification suite for MoonBSDiff Web Studio."""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
STUDIO_DIR = ROOT / "examples" / "web-studio"
DIST_MODULE = STUDIO_DIR / "dist" / "studio.js"
BUILD_SCRIPT = ROOT / "scripts" / "build_web_studio.py"
TARGET_DIR = pathlib.Path(
    os.environ.get("MOONBSDIFF_STUDIO_TARGET_DIR", str(ROOT / "_build" / "web-studio"))
)


def run_node_esm(js_code: str) -> dict:
    proc = subprocess.run(
        ["node", "--input-type=module", "-e", js_code],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"Node harness failed (exit {proc.returncode}):\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    if not lines:
        raise AssertionError("Node harness produced empty stdout")
    return json.loads(lines[-1])


class WebStudioAcceptanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        proc = subprocess.run(
            [
                sys.executable,
                str(BUILD_SCRIPT),
                "--target-dir",
                str(TARGET_DIR),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"build_web_studio.py failed:\n{proc.stdout}\n{proc.stderr}"
            )
        assert DIST_MODULE.is_file(), f"missing staged module: {DIST_MODULE}"

    def test_studio_version_and_exports(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const version = JSON.parse(studio.studio_version());
            console.log(JSON.stringify({ exports: Object.keys(studio).sort(), version }));
            """
        )
        expected_exports = sorted(
            [
                "studio_version",
                "studio_run_graph_scenario",
                "studio_analyze_patch_preset",
                "studio_analyze_patch_hex",
                "studio_trace_stream_apply",
                "studio_run_dir_delta",
            ]
        )
        self.assertEqual(res["exports"], expected_exports)
        self.assertEqual(res["version"]["studio"], "moonbsdiff-web-studio")
        mod_ver = re.search(
            r'^version\s*=\s*"([^"\r\n]+)"',
            (ROOT / "moon.mod").read_text(encoding="utf-8"),
            re.M,
        )
        self.assertIsNotNone(mod_ver)
        self.assertEqual(res["version"]["engine_version"], mod_ver[1])
        self.assertEqual(
            res["version"]["capabilities"],
            ["update_graph", "patch_xray", "stream_oscilloscope", "dir_delta"],
        )

    def test_graph_scenario_routing_rotation_and_redteam(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const run = (req) => JSON.parse(studio.studio_run_graph_scenario(JSON.stringify(req)));
            const out = {
              normal: run({ current_version: 1, target_version: 4, max_steps: 3, allow_full: true, attack_mode: 'none' }),
              fallback_full: run({ current_version: 1, target_version: 4, max_steps: 1, allow_full: true, attack_mode: 'none' }),
              no_route: run({ current_version: 1, target_version: 4, max_steps: 1, allow_full: false, attack_mode: 'none' }),
              budget_exceeded: run({ current_version: 1, target_version: 4, max_steps: 3, max_download_bytes: 100, allow_full: true, attack_mode: 'none' }),
              key_rotation: run({ current_version: 1, target_version: 4, max_steps: 3, allow_full: true, attack_mode: 'key_rotation' }),
              downgrade: run({ current_version: 3, target_version: 1, max_steps: 3, allow_full: true, attack_mode: 'downgrade_v1' }),
              replay: run({ current_version: 1, target_version: 4, max_steps: 3, allow_full: true, attack_mode: 'replay_old_catalog', min_catalog_version: 5 }),
              poison: run({ current_version: 1, target_version: 4, max_steps: 3, allow_full: true, attack_mode: 'poison_fake_patch' }),
              tamper_hop: run({ current_version: 1, target_version: 4, max_steps: 3, allow_full: true, attack_mode: 'tamper_hop' }),
              tamper_hop_max1: run({ current_version: 1, target_version: 4, max_steps: 1, allow_full: true, attack_mode: 'tamper_hop' }),
              invalid_json: JSON.parse(studio.studio_run_graph_scenario('{bad json')),
              float_ver: run({ current_version: 1.9, target_version: 4 }),
              float_steps: run({ current_version: 1, target_version: 4, max_steps: 1.5 }),
              huge_steps: JSON.parse(studio.studio_run_graph_scenario('{"current_version":1,"target_version":4,"max_steps":1e300}')),
              inf_steps: JSON.parse(studio.studio_run_graph_scenario('{"current_version":1,"target_version":4,"max_steps":1e999}')),
              str_min_cat: run({ current_version: 1, target_version: 4, min_catalog_version: '5' }),
            };
            console.log(JSON.stringify(out));
            """
        )

        normal = res["normal"]
        self.assertTrue(normal["ok"])
        self.assertEqual(normal["decision"], "Patches")
        self.assertGreater(normal["full_target_bytes"], normal["total_download_bytes"])
        self.assertGreater(normal["savings_permille"], 800)
        self.assertGreaterEqual(len(normal["verified_steps"]), 2)
        self.assertTrue(all(s["verified"] for s in normal["verified_steps"]))
        self.assertEqual(normal["security_verdict"]["status"], "VERIFIED")

        self.assertTrue(res["fallback_full"]["ok"])
        self.assertEqual(res["fallback_full"]["decision"], "FullFile")

        self.assertFalse(res["no_route"]["ok"])
        self.assertEqual(res["no_route"]["security_verdict"]["code"], "NoRoute")

        self.assertFalse(res["budget_exceeded"]["ok"])
        self.assertEqual(
            res["budget_exceeded"]["security_verdict"]["code"], "BudgetExceeded"
        )

        rot = res["key_rotation"]
        self.assertTrue(rot["ok"])
        self.assertEqual(rot["decision"], "Patches")
        self.assertEqual(len(rot["trusted_key_ids"]), 2)
        self.assertIn(rot["signer_key_id"], rot["trusted_key_ids"])
        self.assertNotEqual(rot["signer_key_id"], normal["signer_key_id"])

        dg = res["downgrade"]
        self.assertFalse(dg["ok"])
        self.assertEqual(dg["security_verdict"]["code"], "DowngradeRejected")

        rp = res["replay"]
        self.assertFalse(rp["ok"])
        self.assertEqual(rp["security_verdict"]["code"], "CatalogRollback")

        ps = res["poison"]
        self.assertFalse(ps["ok"])
        self.assertTrue(ps["security_verdict"]["code"].startswith("Signature"))
        self.assertEqual(
            ps["security_verdict"]["code"], "Signature(VerificationFailed)"
        )
        self.assertTrue(any(e["poisoned"] for e in ps["patches"]))

        th = res["tamper_hop"]
        self.assertFalse(th["ok"])
        self.assertEqual(th["security_verdict"]["code"], "IdentityMismatch")
        self.assertEqual(len(th["verified_steps"]), 1)
        self.assertFalse(th["verified_steps"][0]["verified"])

        inv = res["invalid_json"]
        self.assertFalse(inv["ok"])
        self.assertEqual(inv["security_verdict"]["code"], "InvalidRequest")
        self.assertEqual(inv["verified_steps"], [])
        self.assertEqual(inv["decision"], "Rejected")

        th1 = res["tamper_hop_max1"]
        self.assertFalse(th1["ok"])
        self.assertEqual(th1["security_verdict"]["code"], "IdentityMismatch")
        self.assertEqual(th1["effective_max_steps"], 2)
        self.assertFalse(th1["allow_full"])

        for bad_key in ("float_ver", "float_steps", "huge_steps", "inf_steps", "str_min_cat"):
            bad = res[bad_key]
            self.assertFalse(bad["ok"], bad_key)
            self.assertEqual(bad["security_verdict"]["code"], "InvalidRequest", bad_key)
            self.assertEqual(bad["error"]["kind"], "InvalidRequest", bad_key)

    def test_patch_xray_presets_and_hex_analysis(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const preset = (name, lim) => JSON.parse(studio.studio_analyze_patch_preset(name, lim));
            const bombAudit = preset('decompression_bomb', 'generous');
            const req = bombAudit.required_limits;
            const out = {
              healthy: preset('healthy_update', 'generous'),
              fastpath: preset('fastpath_prefix_suffix', 'generous'),
              bomb_audit: bombAudit,
              bomb_tight: preset('decompression_bomb', 'tight'),
              incompressible: preset('incompressible_random', 'generous'),
              reordered: preset('reordered_blocks', 'generous'),
              truncated: preset('truncated_corrupt', 'generous'),
              hex_tight: JSON.parse(studio.studio_analyze_patch_hex(bombAudit.patch_hex, 65536, 131072, 8192, 512)),
              hex_exact: JSON.parse(studio.studio_analyze_patch_hex(
                bombAudit.patch_hex,
                req.max_patch_bytes,
                req.max_output_bytes,
                req.max_decompressed_bytes,
                req.max_control_instructions
              )),
              bad_hex: JSON.parse(studio.studio_analyze_patch_hex('zzzz', 65536, 65536, 65536, 512)),
            };
            console.log(JSON.stringify(out));
            """
        )

        healthy = res["healthy"]
        self.assertTrue(healthy["ok"])
        self.assertEqual(healthy["risk_level"], "Low")
        self.assertEqual(healthy["risk_flags"], [])
        self.assertEqual(healthy["header"]["header_bytes"], 32)
        self.assertEqual(
            healthy["streams"]["total_compressed_bytes"] + 32,
            healthy["header"]["patch_bytes"],
        )
        self.assertIn("max_decompressed_bytes", healthy["moonbit_snippet"])
        self.assertIn("--max-decompressed-bytes", healthy["cli_flags"])

        fp = res["fastpath"]
        self.assertTrue(fp["ok"])
        self.assertEqual(fp["risk_level"], "Low")
        self.assertEqual(fp["streams"]["control_count"], 2)

        bomb = res["bomb_audit"]
        self.assertTrue(bomb["ok"])
        self.assertEqual(bomb["risk_level"], "High")
        self.assertIn("HIGH_EXPANSION_RATIO", [f["code"] for f in bomb["risk_flags"]])
        self.assertGreaterEqual(bomb["ratios"]["expansion_ratio_permille"], 100000)

        bomb_tight = res["bomb_tight"]
        self.assertFalse(bomb_tight["ok"])
        self.assertEqual(bomb_tight["error"]["kind"], "ResourceLimitExceeded")

        inc = res["incompressible"]
        self.assertTrue(inc["ok"])
        self.assertEqual(inc["risk_level"], "Elevated")
        inc_codes = {f["code"] for f in inc["risk_flags"]}
        self.assertIn("PATCH_LARGER_THAN_OUTPUT", inc_codes)
        self.assertIn("HIGH_EXTRA_RATIO", inc_codes)

        reord = res["reordered"]
        self.assertTrue(reord["ok"])
        self.assertGreater(reord["seeks"]["negative_seek_count"], 0)
        self.assertGreater(reord["seeks"]["max_abs_seek"], 0)

        trunc = res["truncated"]
        self.assertFalse(trunc["ok"])
        self.assertEqual(trunc["error"]["kind"], "TruncatedData")

        self.assertFalse(res["hex_tight"]["ok"])
        self.assertEqual(res["hex_tight"]["error"]["kind"], "ResourceLimitExceeded")

        self.assertTrue(res["hex_exact"]["ok"])
        self.assertEqual(res["hex_exact"]["risk_level"], "High")

        self.assertFalse(res["bad_hex"]["ok"])
        self.assertEqual(res["bad_hex"]["error"]["kind"], "InvalidHex")

    def test_patch_xray_zero_byte_oversize_and_limit_validation(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const healthy = JSON.parse(studio.studio_analyze_patch_preset('healthy_update', 'generous'));
            const hex = healthy.patch_hex;
            const over2mHex = '00'.repeat(2 * 1024 * 1024 + 1);
            const out = {
              zero_byte: JSON.parse(studio.studio_analyze_patch_hex('', 65536, 131072, 262144, 512)),
              over_2m: JSON.parse(studio.studio_analyze_patch_hex(over2mHex, 4194304, 4194304, 4194304, 16384)),
              non_int: JSON.parse(studio.studio_analyze_patch_hex(hex, 100.5, 1048576, 2097152, 16384)),
              nan_lim: JSON.parse(studio.studio_analyze_patch_hex(hex, 65536, Number.NaN, 2097152, 16384)),
              inf_lim: JSON.parse(studio.studio_analyze_patch_hex(hex, 65536, 1048576, Number.POSITIVE_INFINITY, 16384)),
              zero_lim: JSON.parse(studio.studio_analyze_patch_hex(hex, 0, 1048576, 2097152, 16384)),
              neg_lim: JSON.parse(studio.studio_analyze_patch_hex(hex, 65536, 1048576, 2097152, -5)),
              unknown_preset: JSON.parse(studio.studio_analyze_patch_preset('no_such_preset', 'generous')),
            };
            console.log(JSON.stringify(out));
            """
        )

        self.assertFalse(res["zero_byte"]["ok"])
        self.assertEqual(res["zero_byte"]["error"]["kind"], "TruncatedData")
        self.assertEqual(res["zero_byte"]["error"]["stage"], "Header")

        self.assertFalse(res["over_2m"]["ok"])
        self.assertEqual(res["over_2m"]["error"]["kind"], "ResourceLimitExceeded")
        self.assertEqual(res["over_2m"]["error"]["limit"], 2097152)

        self.assertFalse(res["non_int"]["ok"])
        self.assertEqual(res["non_int"]["error"]["kind"], "InvalidConfiguration")
        self.assertEqual(res["non_int"]["error"]["field"], "max_patch_bytes")

        self.assertFalse(res["nan_lim"]["ok"])
        self.assertEqual(res["nan_lim"]["error"]["kind"], "InvalidConfiguration")
        self.assertEqual(res["nan_lim"]["error"]["field"], "max_output_bytes")

        self.assertFalse(res["inf_lim"]["ok"])
        self.assertEqual(res["inf_lim"]["error"]["kind"], "InvalidConfiguration")
        self.assertEqual(res["inf_lim"]["error"]["field"], "max_decompressed_bytes")

        self.assertFalse(res["zero_lim"]["ok"])
        self.assertEqual(res["zero_lim"]["error"]["kind"], "InvalidConfiguration")
        self.assertEqual(res["zero_lim"]["error"]["field"], "max_patch_bytes")
        self.assertEqual(res["zero_lim"]["error"]["value"], 0)

        self.assertFalse(res["neg_lim"]["ok"])
        self.assertEqual(res["neg_lim"]["error"]["kind"], "InvalidConfiguration")
        self.assertEqual(res["neg_lim"]["error"]["field"], "max_control_instructions")
        self.assertEqual(res["neg_lim"]["error"]["value"], -5)

        self.assertFalse(res["unknown_preset"]["ok"])
        self.assertEqual(res["unknown_preset"]["error"]["kind"], "UnknownPreset")

    def test_stream_oscilloscope_complete_and_fail_closed_cancel(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const trace = (name, abortN) => JSON.parse(studio.studio_trace_stream_apply(name, abortN));
            console.log(JSON.stringify({
              complete: trace('firmware_20k', 0),
              mixed: trace('mixed_insert_24k', 0),
              reorder: trace('reorder_seek_16k', 0),
              cancelled: trace('firmware_20k', 2),
            }));
            """
        )

        for key in ("complete", "mixed", "reorder"):
            run = res[key]
            self.assertTrue(run["ok"], key)
            self.assertFalse(run["aborted"], key)
            self.assertTrue(run["final_delivered"], key)
            self.assertTrue(run["sha256_verified"], key)
            self.assertEqual(run["restored_sha256"], run["target_sha256"], key)
            self.assertGreaterEqual(len(run["chunks"]), 4, key)
            self.assertLessEqual(run["max_chunk_bytes"], 4096, key)
            self.assertTrue(all(c["length"] <= 4096 for c in run["chunks"]), key)
            self.assertEqual(
                [s["stage"] for s in run["stages"]],
                ["HeaderVerified", "Restoring", "Validating"],
                key,
            )
            self.assertGreater(run["counters"]["read_old_calls"], 0, key)
            self.assertGreater(run["counters"]["read_patch_calls"], 0, key)

        aborted = res["cancelled"]
        self.assertFalse(aborted["ok"])
        self.assertTrue(aborted["aborted"])
        self.assertFalse(aborted["final_delivered"])
        self.assertFalse(aborted["sha256_verified"])
        self.assertIsNone(aborted["restored_sha256"])
        self.assertEqual(len(aborted["chunks"]), 2)
        self.assertEqual(aborted["error"]["error_type"], "Io")
        self.assertEqual(aborted["error"]["detail"], "cancelled_by_user")

    def test_stream_unknown_preset_and_negative_abort(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            console.log(JSON.stringify({
              unknown: JSON.parse(studio.studio_trace_stream_apply('no_such_stream_preset', 0)),
              neg_abort: JSON.parse(studio.studio_trace_stream_apply('firmware_20k', -7)),
            }));
            """
        )

        unk = res["unknown"]
        self.assertFalse(unk["ok"])
        self.assertFalse(unk["aborted"])
        self.assertFalse(unk["final_delivered"])
        self.assertEqual(unk["error"]["error_type"], "UnknownPreset")

        neg = res["neg_abort"]
        self.assertTrue(neg["ok"])
        self.assertFalse(neg["aborted"])
        self.assertEqual(neg["abort_after_chunks"], 0)
        self.assertTrue(neg["sha256_verified"])

    def test_js_export_boundary_hostile_types(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const healthyHex = JSON.parse(studio.studio_analyze_patch_preset('healthy_update', 'generous')).patch_hex;
            const hostileStrings = [
              ['null', null],
              ['undefined', undefined],
              ['obj', {}],
              ['arr', []],
              ['num', 123],
              ['bool', true],
              ['sym', Symbol('x')],
            ];
            const hostileAborts = [
              ['nan', Number.NaN],
              ['inf', Number.POSITIVE_INFINITY],
              ['ninf', Number.NEGATIVE_INFINITY],
              ['undefined', undefined],
              ['null', null],
              ['obj', {}],
              ['arr', []],
              ['str2', '2'],
              ['float', 0.5],
              ['bool', true],
              ['sym', Symbol('x')],
              ['over_i32', 3000000000],
            ];
            const callSafe = (fn) => {
              const raw = fn();
              return JSON.parse(raw);
            };
            const out = {
              graph: Object.fromEntries(hostileStrings.map(([k, v]) => [k, callSafe(() => studio.studio_run_graph_scenario(v))])),
              dir: Object.fromEntries(hostileStrings.map(([k, v]) => [k, callSafe(() => studio.studio_run_dir_delta(v))])),
              xray_preset_1: Object.fromEntries(hostileStrings.map(([k, v]) => [k, callSafe(() => studio.studio_analyze_patch_preset(v, 'generous'))])),
              xray_preset_2: Object.fromEntries(hostileStrings.map(([k, v]) => [k, callSafe(() => studio.studio_analyze_patch_preset('healthy_update', v))])),
              xray_hex_str: Object.fromEntries(hostileStrings.map(([k, v]) => [k, callSafe(() => studio.studio_analyze_patch_hex(v, 65536, 131072, 262144, 512))])),
              xray_hex_sym_lim: callSafe(() => studio.studio_analyze_patch_hex(healthyHex, Symbol('x'), 131072, 262144, 512)),
              stream_str: Object.fromEntries(hostileStrings.map(([k, v]) => [k, callSafe(() => studio.studio_trace_stream_apply(v, 0))])),
              stream_abort: Object.fromEntries(hostileAborts.map(([k, v]) => [k, callSafe(() => studio.studio_trace_stream_apply('firmware_20k', v))])),
            };
            console.log(JSON.stringify(out));
            """
        )

        for group in ("graph", "dir", "xray_preset_1", "xray_preset_2", "xray_hex_str", "stream_str"):
            for k, val in res[group].items():
                self.assertFalse(val["ok"], f"{group}.{k}")
                self.assertEqual(val["error"]["kind"], "InvalidRequest", f"{group}.{k}")
        for k, val in res["graph"].items():
            self.assertEqual(val["security_verdict"]["code"], "InvalidRequest", k)
        for k, val in res["dir"].items():
            self.assertEqual(val["security_verdict"]["error_type"], "InvalidRequest", k)

        self.assertFalse(res["xray_hex_sym_lim"]["ok"])
        self.assertEqual(res["xray_hex_sym_lim"]["error"]["kind"], "InvalidConfiguration")

        for k, val in res["stream_abort"].items():
            self.assertFalse(val["ok"], f"stream_abort.{k}")
            self.assertEqual(val["abort_after_chunks"], 0, f"stream_abort.{k}")
            self.assertEqual(val["error"]["kind"], "InvalidRequest", f"stream_abort.{k}")
            self.assertEqual(val["error"]["error_type"], "InvalidRequest", f"stream_abort.{k}")

    def test_dir_delta_preset_custom_and_tamper_attacks(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const run = (req) => JSON.parse(studio.studio_run_dir_delta(JSON.stringify(req)));
            const toHex = (s) => Buffer.from(s, 'utf8').toString('hex');
            const out = {
              clean: run({ preset: 'mini_app_v1_to_v2', tamper_mode: 'none' }),
              tamper_blob: run({ preset: 'mini_app_v1_to_v2', tamper_mode: 'tamper_blob' }),
              forged_sig: run({ preset: 'mini_app_v1_to_v2', tamper_mode: 'forged_signature' }),
              traversal: run({ preset: 'mini_app_v1_to_v2', tamper_mode: 'path_traversal' }),
              custom: run({
                tamper_mode: 'none',
                old_files: [
                  { path: 'same.txt', data_hex: toHex('unchanged content 1234567890') },
                  { path: 'oldname.txt', data_hex: toHex('renamed file content 0987654321') },
                  { path: 'drop.txt', data_hex: toHex('obsolete file') },
                ],
                new_files: [
                  { path: 'same.txt', data_hex: toHex('unchanged content 1234567890') },
                  { path: 'newname.txt', data_hex: toHex('renamed file content 0987654321') },
                  { path: 'fresh.txt', data_hex: toHex('brand new file') },
                ],
              }),
            };
            console.log(JSON.stringify(out));
            """
        )

        clean = res["clean"]
        self.assertTrue(clean["ok"])
        self.assertTrue(clean["signature_verified"])
        self.assertTrue(clean["restored_verified"])
        self.assertEqual(clean["restored_tree_sha256"], clean["new_tree_sha256"])
        summary = clean["summary"]
        self.assertGreater(summary["unchanged_count"], 0)
        self.assertGreater(summary["renamed_count"], 0)
        self.assertGreater(summary["patched_count"], 0)
        self.assertGreater(summary["full_fallback_count"], 0)
        self.assertGreater(summary["deleted_count"], 0)
        self.assertGreater(summary["savings_permille"], 800)

        custom = res["custom"]
        self.assertTrue(custom["ok"])
        self.assertEqual(custom["mode"], "custom")
        self.assertEqual(custom["restored_tree_sha256"], custom["new_tree_sha256"])
        self.assertEqual(custom["summary"]["unchanged_count"], 1)
        self.assertEqual(custom["summary"]["renamed_count"], 1)
        self.assertEqual(custom["summary"]["added_count"], 1)
        # Both drop.txt and the vacated oldname.txt path emit Deleted entries.
        self.assertEqual(custom["summary"]["deleted_count"], 2)

        tb = res["tamper_blob"]
        self.assertFalse(tb["ok"])
        self.assertTrue(tb["signature_verified"])
        self.assertFalse(tb["restored_verified"])
        self.assertEqual(tb["security_verdict"]["error_type"], "IdentityMismatch")

        fs = res["forged_sig"]
        self.assertFalse(fs["ok"])
        self.assertFalse(fs["signature_verified"])
        self.assertEqual(
            fs["security_verdict"]["error_type"], "Signature(VerificationFailed)"
        )

        pt = res["traversal"]
        self.assertFalse(pt["ok"])
        self.assertEqual(pt["security_verdict"]["error_type"], "InvalidPath")

        # Verify FULL_FALLBACK entry accurately reports old_bytes from old tree.
        fallback_entries = [e for e in clean["entries"] if e["action"] == "FULL_FALLBACK"]
        self.assertGreater(len(fallback_entries), 0)
        self.assertGreater(fallback_entries[0]["old_bytes"], 0)

    def test_dir_delta_200k_custom_guardrails_and_tamper_edges(self) -> None:
        res = run_node_esm(
            """
            import * as studio from './examples/web-studio/dist/studio.js';
            const run = (req) => JSON.parse(studio.studio_run_dir_delta(JSON.stringify(req)));
            const makePrng = (len, seed) => {
              let s = seed >>> 0;
              const buf = Buffer.alloc(len);
              for (let i = 0; i < len; i++) {
                s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
                buf[i] = (s >>> 24) & 0xff;
              }
              return buf;
            };
            // 200 KiB file: 60 KiB shared prefix + 140 KiB modified random tail -> patch ~140 KiB (128..256 KiB).
            const sharedPrefix = makePrng(60 * 1024, 0x1001);
            const old200k = Buffer.concat([sharedPrefix, makePrng(140 * 1024, 0x2001)]);
            const new200k = Buffer.concat([sharedPrefix, makePrng(140 * 1024, 0x3001)]);

            const tooManyFiles = Array.from({ length: 257 }, (_, i) => ({
              path: `f_${i}.txt`,
              data_hex: '61',
            }));
            const over256kFile = [{ path: 'big.bin', data_hex: '00'.repeat(262145) }];
            // 17 * 256 KiB = 4.25 MiB (> 4 MiB total cap, while count <= 256 and each file <= 256 KiB).
            const chunk256kHex = 'ab'.repeat(262144);
            const over4mTotal = Array.from({ length: 17 }, (_, i) => ({
              path: `part_${i}.bin`,
              data_hex: chunk256kHex,
            }));

            const out = {
              custom_200k: run({
                tamper_mode: 'none',
                old_files: [{ path: 'blob.bin', data_hex: old200k.toString('hex') }],
                new_files: [{ path: 'blob.bin', data_hex: new200k.toString('hex') }],
              }),
              too_many: run({ tamper_mode: 'none', old_files: tooManyFiles, new_files: [] }),
              over_file_cap: run({ tamper_mode: 'none', old_files: over256kFile, new_files: [] }),
              over_total_cap: run({ tamper_mode: 'none', old_files: over4mTotal, new_files: [] }),
              partial_old_only: run({ tamper_mode: 'none', old_files: [{ path: 'a.txt', data_hex: '61' }] }),
              partial_new_only: run({ tamper_mode: 'none', new_files: [{ path: 'a.txt', data_hex: '61' }] }),
              tamper_zero_blobs_identical: run({
                tamper_mode: 'tamper_blob',
                old_files: [{ path: 'same.txt', data_hex: '68656c6c6f' }],
                new_files: [{ path: 'same.txt', data_hex: '68656c6c6f' }],
              }),
              tamper_zero_blobs_empty: run({
                tamper_mode: 'tamper_blob',
                old_files: [],
                new_files: [],
              }),
              tamper_zero_byte_blob: run({
                tamper_mode: 'tamper_blob',
                old_files: [],
                new_files: [{ path: 'empty.txt', data_hex: '' }],
              }),
            };
            console.log(JSON.stringify(out));
            """
        )

        c200 = res["custom_200k"]
        self.assertTrue(c200["ok"], c200)
        self.assertTrue(c200["signature_verified"])
        self.assertTrue(c200["restored_verified"])
        self.assertEqual(c200["restored_tree_sha256"], c200["new_tree_sha256"])
        self.assertEqual(len(c200["entries"]), 1)
        self.assertEqual(c200["entries"][0]["action"], "PATCHED")
        self.assertGreater(c200["entries"][0]["payload_bytes"], 131072)
        self.assertLessEqual(c200["entries"][0]["payload_bytes"], 262144)

        for key in ("too_many", "over_file_cap", "over_total_cap"):
            self.assertFalse(res[key]["ok"], key)
            self.assertEqual(res[key]["security_verdict"]["error_type"], "LimitExceeded", key)

        for key in ("partial_old_only", "partial_new_only"):
            self.assertFalse(res[key]["ok"], key)
            self.assertEqual(res[key]["security_verdict"]["error_type"], "InvalidRequest", key)

        for key in ("tamper_zero_blobs_identical", "tamper_zero_blobs_empty"):
            self.assertFalse(res[key]["ok"], key)
            self.assertFalse(res[key]["restored_verified"], key)
            self.assertEqual(res[key]["security_verdict"]["error_type"], "UnexpectedBlob", key)

        tzb = res["tamper_zero_byte_blob"]
        self.assertFalse(tzb["ok"])
        self.assertFalse(tzb["restored_verified"])
        self.assertEqual(tzb["security_verdict"]["error_type"], "IdentityMismatch")

    def test_web_assets_exist_syntax_and_pure_lf(self) -> None:
        required_files = [
            STUDIO_DIR / "index.html",
            STUDIO_DIR / "styles.css",
            STUDIO_DIR / "app.js",
            STUDIO_DIR / "README.md",
            STUDIO_DIR / ".gitignore",
            DIST_MODULE,
            BUILD_SCRIPT,
            ROOT / "scripts" / "test_web_studio.py",
        ]
        for path in required_files:
            self.assertTrue(path.is_file(), f"missing required file: {path}")

        # Verify zero broken local asset references in index.html and app.js.
        html_text = (STUDIO_DIR / "index.html").read_text(encoding="utf-8")
        for ref in re.findall(r'(?:href|src)="(\./[^"]+)"', html_text):
            resolved = (STUDIO_DIR / ref).resolve()
            self.assertTrue(resolved.is_file(), f"broken HTML asset ref {ref}")

        app_text = (STUDIO_DIR / "app.js").read_text(encoding="utf-8")
        for ref in re.findall(r'import\("(\./[^"]+)"\)', app_text):
            resolved = (STUDIO_DIR / ref).resolve()
            self.assertTrue(resolved.is_file(), f"broken JS dynamic import {ref}")

        # Verify app.js has valid ESM JS syntax via node --check.
        chk = subprocess.run(
            ["node", "--check", str(STUDIO_DIR / "app.js")],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(chk.returncode, 0, f"node --check failed:\n{chk.stderr}")

        # Verify HTML integer step guards and dynamic status elements (no static data-i18n overwrite).
        for input_id in ("xray-max-patch", "xray-max-output", "xray-max-decomp", "xray-max-controls"):
            m = re.search(rf'<input[^>]*id="{input_id}"[^>]*>', html_text)
            self.assertIsNotNone(m, f"missing input #{input_id}")
            self.assertIn('step="1"', m.group(0), f"missing step=1 on #{input_id}")
        for status_id in ("dir-old-status", "dir-new-status"):
            m = re.search(rf'<small[^>]*id="{status_id}"[^>]*>', html_text)
            self.assertIsNotNone(m, f"missing #{status_id}")
            self.assertNotIn("data-i18n", m.group(0), f"static data-i18n on #{status_id} would clobber state")
        for tab in ("graph", "xray", "stream", "dir"):
            self.assertIn(f'id="tab-{tab}"', html_text)
            self.assertIn(f'aria-controls="panel-{tab}"', html_text)
            self.assertIn(f'aria-labelledby="tab-{tab}"', html_text)

        # Verify I18N parity (every data-i18n key in HTML exists in both en and zh, and sets match),
        # plus t() single-pass interpolation safety, escapeHtml('), and hexToBytes strict validation.
        html_i18n_keys = sorted(set(re.findall(r'data-i18n="([^"]+)"', html_text)))
        ui_check = run_node_esm(
            f"""
            import fs from 'node:fs';
            const src = fs.readFileSync('./examples/web-studio/app.js', 'utf8');
            const helperEnd = src.indexOf('function renderEngineBadge');
            const sandbox = new Function(
              src.slice(0, helperEnd) +
              '\\nreturn {{ I18N, t, escapeHtml, hexToBytes }};'
            )();
            const enKeys = Object.keys(sandbox.I18N.en).sort();
            const zhKeys = Object.keys(sandbox.I18N.zh).sort();
            let oddRejected = false;
            try {{ sandbox.hexToBytes('abc'); }} catch {{ oddRejected = true; }}
            let badCharRejected = false;
            try {{ sandbox.hexToBytes('zzzz'); }} catch {{ badCharRejected = true; }}
            const emptyLen = sandbox.hexToBytes('').length;
            const escaped = sandbox.escapeHtml("<'\\"&>");
            const hostileInterpolated = sandbox.t('err_patch_too_large', {{
              name: 'foo_{{size}}_$$_$&.patch',
              size: '3,145,728',
              limit: '2,097,152',
            }});
            console.log(JSON.stringify({{
              enKeys,
              zhKeys,
              oddRejected,
              badCharRejected,
              emptyLen,
              escaped,
              hostileInterpolated,
            }}));
            """
        )
        self.assertEqual(ui_check["enKeys"], ui_check["zhKeys"])
        for key in html_i18n_keys:
            self.assertIn(key, ui_check["enKeys"], f"missing I18N key: {key}")
        self.assertTrue(ui_check["oddRejected"])
        self.assertTrue(ui_check["badCharRejected"])
        self.assertEqual(ui_check["emptyLen"], 0)
        self.assertEqual(ui_check["escaped"], "&lt;&#39;&quot;&amp;&gt;")
        self.assertIn("foo_{size}_$$_$&.patch", ui_check["hostileInterpolated"])
        self.assertIn("3,145,728", ui_check["hostileInterpolated"])

        # Verify pure LF (no CRLF and no lone CR) on all source files owned by Web Studio.
        lf_checked = [
            *(ROOT / "cmd" / "studio").glob("*.mbt"),
            ROOT / "cmd" / "studio" / "moon.pkg",
            STUDIO_DIR / "index.html",
            STUDIO_DIR / "styles.css",
            STUDIO_DIR / "app.js",
            STUDIO_DIR / "README.md",
            STUDIO_DIR / ".gitignore",
            BUILD_SCRIPT,
            ROOT / "scripts" / "test_web_studio.py",
        ]
        for path in lf_checked:
            raw = path.read_bytes()
            self.assertNotIn(b"\r", raw, f"CR/CRLF detected in {path}")


if __name__ == "__main__":
    unittest.main()
