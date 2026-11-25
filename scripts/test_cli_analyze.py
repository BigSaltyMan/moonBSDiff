"""Native CLI tests for inspect --analyze and inspect --analyze --json."""

import argparse
import bz2
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_cli import ROOT
from test_cli_stream import envelope, integer


EXE = None


def build_patch_envelope(triples, diff_bytes, extra_bytes, new_size):
    control = b"".join(integer(v) for triple in triples for v in triple)
    packed = [bz2.compress(block) for block in (control, diff_bytes, extra_bytes)]
    return envelope(packed, new_size), packed


def lcg_bytes(seed, length):
    state = seed & 0xFFFFFFFF
    out = bytearray(length)
    for i in range(length):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        out[i] = (state >> 24) & 0xFF
    return bytes(out)


class AnalyzeCli(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonbsdiff-analyze-")
        self.addCleanup(self.temp.cleanup)
        self.p = Path(self.temp.name)

    def run_cli(self, args, code=0):
        before = {
            p.name: (p.read_bytes(), p.stat().st_mtime_ns)
            for p in self.p.iterdir()
            if p.is_file()
        }
        result = subprocess.run(
            [str(EXE), *map(str, args)],
            cwd=self.p,
            capture_output=True,
            timeout=30,
        )
        self.assertEqual(
            result.returncode,
            code,
            result.stderr.decode("utf-8", errors="replace"),
        )
        if code:
            self.assertEqual(result.stdout, b"")
            self.assertTrue(result.stderr)
        else:
            self.assertEqual(result.stderr, b"")
        if args and args[0] == "inspect":
            after = {
                p.name: (p.read_bytes(), p.stat().st_mtime_ns)
                for p in self.p.iterdir()
                if p.is_file()
            }
            self.assertEqual(before, after)
        return result

    def test_healthy_patch_text_json_and_required_limits_roundtrip(self):
        old_data = lcg_bytes(0x12345678, 4096)
        new_data = old_data[:2000] + b"HEALTHY-PATCH-EDIT" + old_data[2018:]
        old_path = self.p / "old.bin"
        new_path = self.p / "new.bin"
        patch_path = self.p / "healthy.patch"
        old_path.write_bytes(old_data)
        new_path.write_bytes(new_data)
        self.run_cli(["diff", old_path, new_path, patch_path])

        raw_patch = patch_path.read_bytes()
        ctrl_len = int.from_bytes(raw_patch[8:16], "little")
        diff_len = int.from_bytes(raw_patch[16:24], "little")
        new_len = int.from_bytes(raw_patch[24:32], "little")
        extra_len = len(raw_patch) - 32 - ctrl_len - diff_len

        res_json = self.run_cli(["inspect", "--analyze", "--json", patch_path])
        doc = json.loads(res_json.stdout)
        self.assertEqual(doc["schema_version"], 1)
        self.assertEqual(doc["format"], "BSDIFF40")
        self.assertEqual(doc["patch_path"], str(patch_path))
        self.assertEqual(doc["validation"], "analyze")
        self.assertEqual(
            doc["header"],
            {
                "patch_bytes": str(len(raw_patch)),
                "new_bytes": str(new_len),
                "control_length": str(ctrl_len),
                "diff_length": str(diff_len),
                "extra_length": str(extra_len),
            },
        )
        deep = doc["deep"]
        self.assertEqual(
            int(deep["diff_bytes"]) + int(deep["extra_bytes"]),
            len(new_data),
        )
        self.assertEqual(
            int(deep["expanded_bytes"]),
            24 * int(deep["control_count"]) + len(new_data),
        )
        ratios = doc["ratios"]
        self.assertLess(int(ratios["patch_to_output_permille"]), 1000)
        self.assertGreater(int(ratios["diff_share_permille"]), 800)
        self.assertEqual(set(doc["seeks"]), {"negative_seek_count", "max_abs_seek"})
        self.assertEqual(doc["risk_level"], "low")
        self.assertEqual(doc["risk_flags"], [])
        self.assertTrue(len(doc["sample_controls"]) >= 1)
        self.assertEqual(
            set(doc["sample_controls"][0]),
            {"index", "add_bytes", "extra_bytes", "seek_offset"},
        )

        # Text mode contains key human-readable fields.
        text = self.run_cli(["inspect", "--analyze", patch_path]).stdout.decode("utf-8")
        for needle in (
            "Format: BSDIFF40",
            "Validation: analyze",
            f"Patch bytes: {len(raw_patch)}",
            "Risk level: low",
            "Risk flags: none",
            "Required limits:",
            "Sample controls:",
        ):
            self.assertIn(needle, text)

        # Exact required_limits work for both inspect --analyze and patch.
        req = doc["required_limits"]
        self.assertEqual(req["max_patch_bytes"], str(len(raw_patch)))
        self.assertEqual(req["max_new_bytes"], str(len(new_data)))
        self.assertEqual(req["max_output_bytes"], str(len(new_data)))
        self.assertEqual(req["max_decompressed_bytes"], deep["expanded_bytes"])
        self.assertEqual(req["max_control_instructions"], deep["control_count"])

        # Re-run with exact limits using both CLI flag spellings.
        re_doc = json.loads(
            self.run_cli([
                "inspect",
                "--analyze",
                "--json",
                "--max-patch-bytes",
                req["max_patch_bytes"],
                "--max-output-bytes",
                req["max_output_bytes"],
                "--max-decompressed-bytes",
                req["max_decompressed_bytes"],
                "--max-control-instructions",
                req["max_control_instructions"],
                patch_path,
            ]).stdout
        )
        self.assertEqual(re_doc, doc)

        restored = self.p / "restored.bin"
        self.run_cli([
            "patch",
            "--max-old-bytes",
            str(len(old_data)),
            "--max-new-bytes",
            req["max_new_bytes"],
            "--max-output-bytes",
            req["max_output_bytes"],
            "--max-patch-bytes",
            req["max_patch_bytes"],
            "--max-expanded-bytes",
            req["max_decompressed_bytes"],
            "--max-controls",
            req["max_control_instructions"],
            old_path,
            patch_path,
            restored,
        ])
        self.assertEqual(restored.read_bytes(), new_data)

    def test_fast_path_identical_and_empty_patch(self):
        same_data = lcg_bytes(0xCAFEBABE, 4096)
        old_path = self.p / "same_old.bin"
        new_path = self.p / "same_new.bin"
        patch_path = self.p / "identical.patch"
        old_path.write_bytes(same_data)
        new_path.write_bytes(same_data)
        self.run_cli(["diff", old_path, new_path, patch_path])

        doc = json.loads(self.run_cli(["inspect", "--analyze", "--json", patch_path]).stdout)
        self.assertEqual(doc["deep"]["control_count"], "1")
        self.assertEqual(doc["ratios"]["diff_share_permille"], "1000")
        self.assertEqual(doc["ratios"]["extra_share_permille"], "0")
        self.assertEqual(doc["risk_level"], "low")
        self.assertEqual(doc["risk_flags"], [])
        self.assertEqual(
            doc["sample_controls"],
            [{"index": "0", "add_bytes": "4096", "extra_bytes": "0", "seek_offset": "0"}],
        )

        # Empty-to-empty patch (both-empty upstream fixture).
        empty_patch = self.p / "empty.patch"
        empty_patch.write_bytes((ROOT / "testdata/upstream/both-empty/patch.bin").read_bytes())
        empty_doc = json.loads(self.run_cli(["inspect", "--analyze", "--json", empty_patch]).stdout)
        self.assertEqual(empty_doc["header"]["new_bytes"], "0")
        self.assertEqual(empty_doc["deep"]["control_count"], "0")
        self.assertEqual(empty_doc["deep"]["expanded_bytes"], "0")
        self.assertEqual(empty_doc["risk_level"], "low")
        self.assertEqual(empty_doc["sample_controls"], [])
        for key in ("max_new_bytes", "max_output_bytes", "max_decompressed_bytes", "max_control_instructions"):
            self.assertEqual(empty_doc["required_limits"][key], "1")

    def test_high_expansion_and_elevated_risk_flags_and_seeks(self):
        # 1. High expansion ratio (>= 100x and >= 64 KiB expanded): all-zero diff block.
        big_size = 131072
        high_patch_bytes, _ = build_patch_envelope(
            [(big_size, 0, 0)],
            bytes(big_size),
            b"",
            big_size,
        )
        high_patch = self.p / "high-expansion.patch"
        high_patch.write_bytes(high_patch_bytes)
        high_doc = json.loads(
            self.run_cli(["inspect", "--analyze", "--json", high_patch]).stdout
        )
        self.assertEqual(high_doc["risk_level"], "high")
        codes = {f["code"]: f["severity"] for f in high_doc["risk_flags"]}
        self.assertEqual(codes.get("HIGH_EXPANSION_RATIO"), "high")
        self.assertGreaterEqual(int(high_doc["ratios"]["expansion_ratio_permille"]), 100000)

        text_high = self.run_cli(["inspect", "--analyze", high_patch]).stdout.decode("utf-8")
        self.assertIn("Risk level: high", text_high)
        self.assertIn("[high] HIGH_EXPANSION_RATIO:", text_high)

        # 2. Patch larger than output + negative seeks + exact sample controls.
        triples = [(2, 1, -5), (1, 2, -9)]
        small_patch_bytes, _ = build_patch_envelope(triples, b"abc", b"XYZ", 6)
        small_patch = self.p / "small-seeks.patch"
        small_patch.write_bytes(small_patch_bytes)
        small_doc = json.loads(
            self.run_cli(["inspect", "--analyze", "--json", small_patch]).stdout
        )
        self.assertEqual(small_doc["risk_level"], "elevated")
        small_codes = {f["code"]: f["severity"] for f in small_doc["risk_flags"]}
        self.assertEqual(small_codes.get("PATCH_LARGER_THAN_OUTPUT"), "elevated")
        self.assertEqual(
            small_doc["seeks"],
            {"negative_seek_count": "2", "max_abs_seek": "9"},
        )
        self.assertEqual(
            small_doc["sample_controls"],
            [
                {"index": "0", "add_bytes": "2", "extra_bytes": "1", "seek_offset": "-5"},
                {"index": "1", "add_bytes": "1", "extra_bytes": "2", "seek_offset": "-9"},
            ],
        )

        # 3. High extra ratio (new file written entirely via extra stream).
        old_empty = self.p / "empty_old.bin"
        new_rand = self.p / "rand_new.bin"
        extra_patch = self.p / "all_extra.patch"
        old_empty.write_bytes(b"")
        new_rand.write_bytes(lcg_bytes(0x99887766, 512))
        self.run_cli(["diff", old_empty, new_rand, extra_patch])
        extra_doc = json.loads(
            self.run_cli(["inspect", "--analyze", "--json", extra_patch]).stdout
        )
        extra_codes = {f["code"]: f["severity"] for f in extra_doc["risk_flags"]}
        self.assertEqual(extra_codes.get("HIGH_EXTRA_RATIO"), "elevated")
        self.assertEqual(extra_doc["ratios"]["extra_share_permille"], "1000")

    def test_tight_limits_and_corrupt_patch_rejection(self):
        triples = [(2, 1, -5), (0, 0, 4), (1, 2, 0)]
        patch_bytes, packed = build_patch_envelope(triples, b"abc", b"XYZ", 6)
        patch_path = self.p / "bounded.patch"
        patch_path.write_bytes(patch_bytes)

        doc = json.loads(
            self.run_cli(["inspect", "--analyze", "--json", patch_path]).stdout
        )
        req = doc["required_limits"]
        self.assertEqual(req["max_decompressed_bytes"], "78")
        self.assertEqual(req["max_control_instructions"], "3")
        self.assertEqual(req["max_output_bytes"], "6")

        for opt, val, diag in (
            ("--max-patch-bytes", str(len(patch_bytes) - 1), b"byte limit"),
            ("--max-output-bytes", "5", b"max_output_bytes"),
            ("--max-expanded-bytes", "77", b"decompressed_remaining"),
            ("--max-decompressed-bytes", "77", b"decompressed_remaining"),
            ("--max-controls", "2", b"max_control_instructions"),
            ("--max-control-instructions", "2", b"max_control_instructions"),
        ):
            with self.subTest(opt=opt, val=val):
                err = self.run_cli(["inspect", "--analyze", opt, val, "--json", patch_path], code=1).stderr
                self.assertIn(diag, err)

        # Corrupt CRC fails closed.
        damaged = bytearray(packed[1])
        damaged[10] ^= 1
        bad_patch = self.p / "bad-crc.patch"
        bad_patch.write_bytes(envelope([packed[0], bytes(damaged), packed[2]], 6))
        err = self.run_cli(["inspect", "--analyze", "--json", bad_patch], code=1).stderr
        self.assertIn(b"DecompressionFailed", err)

    def test_invalid_arguments_and_help(self):
        patch_path = self.p / "dummy.patch"
        patch_path.write_bytes(b"")
        help_out = self.run_cli(["inspect", "--help"]).stdout.decode("utf-8")
        self.assertIn("--analyze", help_out)
        self.assertIn("--deep", help_out)

        invalid_rows = [
            ["inspect", "--deep", "--analyze", patch_path],
            ["inspect", "--analyze", "--deep", patch_path],
            ["inspect", "--analyze", "--analyze", patch_path],
            ["inspect", "--analyze"],
            ["inspect", "--analyze", patch_path, patch_path],
            ["inspect", "--max-decompressed-bytes", "100", patch_path],
            ["inspect", "--max-control-instructions", "10", patch_path],
            ["inspect", "--analyze", "--max-expanded-bytes", "100", "--max-decompressed-bytes", "100", patch_path],
            ["inspect", "--analyze", "--max-controls", "10", "--max-control-instructions", "10", patch_path],
            ["inspect", "--analyze", "--max-old-bytes", "100", patch_path],
            ["diff", "--analyze", patch_path, patch_path, self.p / "x"],
        ]
        for argv in invalid_rows:
            with self.subTest(argv=argv):
                self.run_cli(argv, code=2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(AnalyzeCli)
    )
    if not result.wasSuccessful() or result.testsRun != 5 or result.skipped:
        raise SystemExit(1)
