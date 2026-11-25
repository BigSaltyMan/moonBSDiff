"""Native CLI tests for release catalogs, multi-key rotation, and signed chains."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


EXE = None


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def make_catalog(channel, catalog_version, min_version, releases, patches):
    return json.dumps(
        {
            "schema": 1,
            "type": "moonbsdiff-release-catalog",
            "channel": channel,
            "catalog_version": catalog_version,
            "min_version": min_version,
            "releases": releases,
            "patches": patches,
        },
        separators=(",", ":"),
    ).encode("utf-8") + b"\n"


def lcg_bytes(seed, length):
    state = seed & 0xFFFFFFFF
    out = bytearray(length)
    for i in range(length):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        out[i] = (state >> 24) & 0xFF
    return bytes(out)


class CatalogAndSignedChainCli(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonbsdiff-catalog-")
        self.addCleanup(self.temp.cleanup)
        self.p = Path(self.temp.name)

        # Build 3 versions with real patches where 2-hop (v1->v2->v3) is smaller than
        # direct (v1->v3) and full v3, while direct v1->v3 is larger than full v3.
        self.v1_bytes = lcg_bytes(0x10101010, 4096)
        self.v2_bytes = self.v1_bytes[:1024] + b"RELEASE-V2-DELTA" + self.v1_bytes[1040:]
        self.v3_bytes = self.v2_bytes[:2048] + b"RELEASE-V3-DELTA" + self.v2_bytes[2064:]

        self.v1 = self.p / "v1.bin"
        self.v2 = self.p / "v2.bin"
        self.v3 = self.p / "v3.bin"
        self.v1.write_bytes(self.v1_bytes)
        self.v2.write_bytes(self.v2_bytes)
        self.v3.write_bytes(self.v3_bytes)

        self.p12 = self.p / "v1-to-v2.patch"
        self.m12 = self.p / "v1-to-v2.json"
        self.p23 = self.p / "v2-to-v3.patch"
        self.m23 = self.p / "v2-to-v3.json"
        self.p13 = self.p / "v1-to-v3.patch"
        self.m13 = self.p / "v1-to-v3.json"

        self.run_cli(["diff", "--manifest", self.m12, self.v1, self.v2, self.p12])
        self.run_cli(["diff", "--manifest", self.m23, self.v2, self.v3, self.p23])
        self.run_cli(["diff", "--manifest", self.m13, self.v1, self.v3, self.p13])

        # Generate 3 keypairs: key1 (old), key2 (rotated new), key3 (untrusted).
        self.priv1, self.pub1 = self.p / "k1.key", self.p / "k1.pub"
        self.priv2, self.pub2 = self.p / "k2.key", self.p / "k2.pub"
        self.priv3, self.pub3 = self.p / "k3.key", self.p / "k3.pub"
        self.k1_meta = json.loads(self.run_cli(["manifest", "keygen", "--json", self.priv1, self.pub1]).stdout)
        self.k2_meta = json.loads(self.run_cli(["manifest", "keygen", "--json", self.priv2, self.pub2]).stdout)
        self.k3_meta = json.loads(self.run_cli(["manifest", "keygen", "--json", self.priv3, self.pub3]).stdout)

        # Catalog where 2-hop (p12 + p23) is cheaper than a large direct edge (5000 B declared).
        self.p12_bytes = self.p12.read_bytes()
        self.p23_bytes = self.p23.read_bytes()
        self.p13_bytes = self.p13.read_bytes()
        self.assertLess(len(self.p12_bytes) + len(self.p23_bytes), len(self.v3_bytes))

        self.releases = [
            {"version": 1, "label": "1.0.0", "size_bytes": len(self.v1_bytes), "sha256": sha256_hex(self.v1_bytes)},
            {"version": 2, "label": "2.0.0", "size_bytes": len(self.v2_bytes), "sha256": sha256_hex(self.v2_bytes)},
            {"version": 3, "label": "3.0.0", "size_bytes": len(self.v3_bytes), "sha256": sha256_hex(self.v3_bytes)},
        ]
        # Give the direct edge a 5000-byte declared size so 2-hop wins over direct and full-file wins over 1-hop.
        self.patches = [
            {
                "from_version": 1,
                "to_version": 2,
                "patch_size_bytes": len(self.p12_bytes),
                "patch_sha256": sha256_hex(self.p12_bytes),
                "manifest_sha256": sha256_hex(self.m12.read_bytes()),
                "uri": "https://cdn.example/patches/v1-to-v2.patch",
            },
            {
                "from_version": 2,
                "to_version": 3,
                "patch_size_bytes": len(self.p23_bytes),
                "patch_sha256": sha256_hex(self.p23_bytes),
                "manifest_sha256": sha256_hex(self.m23.read_bytes()),
                "uri": "https://cdn.example/patches/v2-to-v3.patch",
            },
            {
                "from_version": 1,
                "to_version": 3,
                "patch_size_bytes": 5000,
                "patch_sha256": sha256_hex(self.p13_bytes),
                "uri": "https://cdn.example/patches/v1-to-v3.patch",
            },
        ]
        self.catalog = self.p / "catalog.json"
        self.catalog.write_bytes(make_catalog("stable", 5, 1, self.releases, self.patches))

    def run_cli(self, args, code=0):
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
        return result

    def test_catalog_sign_verify_and_multi_key_rotation(self):
        sig1 = self.p / "catalog-k1.sig"
        sig2 = self.p / "catalog-k2.sig"

        # Sign with key1 (JSON) and key2 (text).
        meta1 = json.loads(
            self.run_cli([
                "manifest", "catalog", "sign", "--private-key", self.priv1, "--json",
                self.catalog, sig1,
            ]).stdout
        )
        cat_hash = sha256_hex(self.catalog.read_bytes())
        self.assertEqual(
            meta1,
            {
                "schema_version": 1,
                "algorithm": "ed25519",
                "key_id": self.k1_meta["key_id"],
                "catalog_sha256": cat_hash,
                "catalog_path": str(self.catalog),
                "signature_path": str(sig1),
            },
        )
        # No-overwrite on existing signature and alias refusal.
        self.run_cli(["manifest", "catalog", "sign", "--private-key", self.priv1, self.catalog, sig1], code=1)
        self.run_cli(["manifest", "catalog", "sign", "--private-key", self.priv1, self.catalog, self.catalog], code=1)
        self.run_cli(["manifest", "catalog", "sign", "--private-key", self.priv1, self.catalog, self.priv1], code=1)

        text_sign = self.run_cli([
            "manifest", "catalog", "sign", "--private-key", self.priv2, self.catalog, sig2,
        ]).stdout.decode("utf-8")
        self.assertIn(self.k2_meta["key_id"], text_sign)

        # Verify key1-signed catalog with [key2, key1] trust store (rotation!).
        ver1 = json.loads(
            self.run_cli([
                "manifest", "catalog", "verify",
                "--public-key", self.pub2,
                "--public-key", self.pub1,
                "--signature", sig1,
                "--json",
                self.catalog,
            ]).stdout
        )
        self.assertTrue(ver1["valid"])
        self.assertEqual(ver1["signer_key_id"], self.k1_meta["key_id"])
        self.assertEqual(ver1["catalog_sha256"], cat_hash)
        self.assertEqual(ver1["channel"], "stable")
        self.assertEqual(ver1["catalog_version"], "5")
        self.assertEqual(ver1["min_version"], "1")
        self.assertEqual(ver1["release_count"], 3)
        self.assertEqual(ver1["patch_count"], 3)

        # Verify key2-signed catalog with [key1, key2] trust store (text mode).
        ver2_text = self.run_cli([
            "manifest", "catalog", "verify",
            "--public-key", self.pub1,
            "--public-key", self.pub2,
            "--signature", sig2,
            self.catalog,
        ]).stdout.decode("utf-8")
        self.assertIn(self.k2_meta["key_id"], ver2_text)
        self.assertIn("catalog_version 5", ver2_text)

        # Untrusted key3 fails with key_id mismatch.
        err = self.run_cli([
            "manifest", "catalog", "verify",
            "--public-key", self.pub3,
            "--signature", sig1,
            "--json",
            self.catalog,
        ], code=1).stderr
        self.assertIn(b"key_id mismatch", err)

        # Multi-key rotation also works across manifest verify-sig, verify, patch, and install-full.
        m12_sig = self.p / "m12-k2.sig"
        self.run_cli(["manifest", "sign", "--private-key", self.priv2, self.m12, m12_sig])
        vsig = json.loads(
            self.run_cli([
                "manifest", "verify-sig", "--json",
                "--public-key", self.pub1, "--public-key", self.pub2,
                "--signature", m12_sig, self.m12,
            ]).stdout
        )
        self.assertTrue(vsig["valid"])
        self.assertEqual(vsig["key_id"], self.k2_meta["key_id"])
        self.assertEqual(vsig["public_key_path"], str(self.pub2))

        for stream_flag in ([], ["--stream"]):
            self.run_cli([
                "verify", *stream_flag, "--manifest", self.m12,
                "--public-key", self.pub1, "--public-key", self.pub2,
                "--signature", m12_sig, self.v1, self.p12,
            ])
        rotated_out = self.p / "rotated-patch.bin"
        self.run_cli([
            "patch", "--manifest", self.m12,
            "--public-key", self.pub1, "--public-key", self.pub2,
            "--signature", m12_sig, self.v1, self.p12, rotated_out,
        ])
        self.assertEqual(rotated_out.read_bytes(), self.v2_bytes)

        rotated_full = self.p / "rotated-full.bin"
        self.run_cli([
            "install-full", "--target-manifest", self.m12,
            "--public-key", self.pub1, "--public-key", self.pub2,
            "--signature", m12_sig, self.v2, rotated_full,
        ])
        self.assertEqual(rotated_full.read_bytes(), self.v2_bytes)

    def test_catalog_plan_routes_full_fallback_up_to_date_and_budget(self):
        sig = self.p / "catalog.sig"
        self.run_cli(["manifest", "catalog", "sign", "--private-key", self.priv1, self.catalog, sig])

        # 1. Optimal 2-hop patch route (v1 -> v2 -> v3).
        plan = json.loads(
            self.run_cli([
                "manifest", "catalog", "plan",
                "--public-key", self.pub2, "--public-key", self.pub1,
                "--signature", sig,
                "--current-version", "1",
                "--target-version", "3",
                "--json",
                self.catalog, self.v1,
            ]).stdout
        )
        expected_total = len(self.p12_bytes) + len(self.p23_bytes)
        self.assertEqual(plan["signer_key_id"], self.k1_meta["key_id"])
        self.assertEqual(plan["catalog_version"], "5")
        self.assertEqual(plan["channel"], "stable")
        self.assertEqual(plan["min_version"], "1")
        self.assertEqual(plan["decision"], "patches")
        self.assertEqual(plan["total_download_bytes"], str(expected_total))
        self.assertEqual(len(plan["steps"]), 2)
        self.assertEqual(plan["steps"][0]["patch_index"], 0)
        self.assertEqual(plan["steps"][0]["from_version"], "1")
        self.assertEqual(plan["steps"][0]["to_version"], "2")
        self.assertEqual(plan["steps"][0]["patch_size_bytes"], str(len(self.p12_bytes)))
        self.assertEqual(plan["steps"][0]["patch_sha256"], sha256_hex(self.p12_bytes))
        self.assertEqual(plan["steps"][0]["uri"], "https://cdn.example/patches/v1-to-v2.patch")
        self.assertEqual(plan["steps"][1]["patch_index"], 1)
        self.assertEqual(plan["steps"][1]["from_version"], "2")
        self.assertEqual(plan["steps"][1]["to_version"], "3")

        # Human-readable text output also succeeds.
        plan_text = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1,
            "--signature", sig,
            "--current-version", "1",
            "--target-version", "3",
            self.catalog, self.v1,
        ]).stdout.decode("utf-8")
        self.assertIn("Decision: patches", plan_text)
        self.assertIn("v1 -> v2", plan_text)
        self.assertIn("v2 -> v3", plan_text)

        # 2. --max-steps 1 without --allow-full chooses direct 5000-byte edge.
        direct_plan = json.loads(
            self.run_cli([
                "manifest", "catalog", "plan",
                "--public-key", self.pub1, "--signature", sig,
                "--current-version", "1", "--target-version", "3",
                "--max-steps", "1", "--json",
                self.catalog, self.v1,
            ]).stdout
        )
        self.assertEqual(direct_plan["decision"], "patches")
        self.assertEqual(direct_plan["total_download_bytes"], "5000")
        self.assertEqual([s["patch_index"] for s in direct_plan["steps"]], [2])

        # 3. --max-steps 1 WITH --allow-full falls back to 4096-byte full file.
        full_plan = json.loads(
            self.run_cli([
                "manifest", "catalog", "plan",
                "--public-key", self.pub1, "--signature", sig,
                "--current-version", "1", "--target-version", "3",
                "--max-steps", "1", "--allow-full", "--json",
                self.catalog, self.v1,
            ]).stdout
        )
        self.assertEqual(full_plan["decision"], "full-file")
        self.assertEqual(full_plan["total_download_bytes"], str(len(self.v3_bytes)))
        self.assertEqual(full_plan["steps"], [])

        # 4. Already up-to-date.
        up_plan = json.loads(
            self.run_cli([
                "manifest", "catalog", "plan",
                "--public-key", self.pub1, "--signature", sig,
                "--current-version", "3", "--target-version", "3",
                "--max-download-bytes", "0", "--json",
                self.catalog, self.v3,
            ]).stdout
        )
        self.assertEqual(up_plan["decision"], "up-to-date")
        self.assertEqual(up_plan["total_download_bytes"], "0")
        self.assertEqual(up_plan["steps"], [])

        # 5. Budget boundary check.
        self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", sig,
            "--current-version", "1", "--target-version", "3",
            "--max-download-bytes", str(expected_total), "--json",
            self.catalog, self.v1,
        ])
        err_budget = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", sig,
            "--current-version", "1", "--target-version", "3",
            "--max-download-bytes", str(expected_total - 1), "--json",
            self.catalog, self.v1,
        ], code=1).stderr
        self.assertIn(b"exceeds budget", err_budget)

        # 6. Mismatched CURRENT_FILE content fails closed.
        err_id = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", sig,
            "--current-version", "1", "--target-version", "3",
            "--json", self.catalog, self.v2,
        ], code=1).stderr
        self.assertIn(b"identity mismatch", err_id)

    def test_anti_downgrade_anti_replay_and_tampering_rejections(self):
        # Catalog with catalog_version=5, min_version=2.
        floor_cat = self.p / "floor-catalog.json"
        floor_cat.write_bytes(make_catalog("stable", 5, 2, self.releases, self.patches))
        floor_sig = self.p / "floor-catalog.sig"
        self.run_cli(["manifest", "catalog", "sign", "--private-key", self.priv1, floor_cat, floor_sig])

        # 1. Anti-downgrade: target < current_version (3 -> 2).
        err_down1 = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", floor_sig,
            "--current-version", "3", "--target-version", "2",
            "--json", floor_cat, self.v3,
        ], code=1).stderr
        self.assertIn(b"downgrade rejected", err_down1)

        # 2. Anti-downgrade: target < min_version (1 -> 1 when min_version=2).
        err_down2 = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", floor_sig,
            "--current-version", "1", "--target-version", "1",
            "--json", floor_cat, self.v1,
        ], code=1).stderr
        self.assertIn(b"downgrade rejected", err_down2)

        # 3. Anti-replay: --min-catalog-version 5 passes, 6 fails BEFORE opening missing CURRENT_FILE.
        self.run_cli([
            "manifest", "catalog", "verify",
            "--public-key", self.pub1, "--signature", floor_sig,
            "--min-catalog-version", "5", floor_cat,
        ])
        err_replay_v = self.run_cli([
            "manifest", "catalog", "verify",
            "--public-key", self.pub1, "--signature", floor_sig,
            "--min-catalog-version", "6", floor_cat,
        ], code=1).stderr
        self.assertIn(b"catalog rollback rejected", err_replay_v)

        missing_cur = self.p / "does-not-exist.bin"
        err_replay_p = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", floor_sig,
            "--current-version", "2", "--target-version", "3",
            "--min-catalog-version", "6", floor_cat, missing_cur,
        ], code=1).stderr
        self.assertIn(b"catalog rollback rejected", err_replay_p)
        self.assertNotIn(b"read current file", err_replay_p)

        # 4. Tampered catalog rejected BEFORE opening missing CURRENT_FILE.
        tampered_cat = self.p / "tampered-catalog.json"
        tampered_cat.write_bytes(floor_cat.read_bytes() + b" ")
        err_tcat = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", floor_sig,
            "--current-version", "2", "--target-version", "3",
            tampered_cat, missing_cur,
        ], code=1).stderr
        self.assertIn(b"catalog_sha256 mismatch", err_tcat)
        self.assertNotIn(b"read current file", err_tcat)

        # 5. Tampered signature rejected.
        sig_obj = json.loads(floor_sig.read_bytes())
        flipped = ("0" if sig_obj["signature"][0] != "0" else "1") + sig_obj["signature"][1:]
        bad_sig = self.p / "bad-cat.sig"
        bad_sig.write_text(json.dumps(dict(sig_obj, signature=flipped)), encoding="utf-8")
        err_tsig = self.run_cli([
            "manifest", "catalog", "verify",
            "--public-key", self.pub1, "--signature", bad_sig, floor_cat,
        ], code=1).stderr
        self.assertTrue(b"signature" in err_tsig or b"verification failed" in err_tsig, err_tsig)

        # 6. Invalid arguments exit 2 & help pages exit 0.
        for help_args in (
            ["manifest", "--help"],
            ["manifest", "catalog", "--help"],
            ["manifest", "catalog", "sign", "--help"],
            ["manifest", "catalog", "verify", "--help"],
            ["manifest", "catalog", "plan", "--help"],
        ):
            self.run_cli(help_args, code=0)

        for bad_args in (
            ["manifest", "catalog"],
            ["manifest", "catalog", "unknown"],
            ["manifest", "catalog", "sign", floor_cat, self.p / "x.sig"],
            ["manifest", "catalog", "verify", "--public-key", self.pub1, floor_cat],
            ["manifest", "catalog", "verify", "--signature", floor_sig, floor_cat],
            ["manifest", "catalog", "verify", "--public-key", self.pub1, "--signature", floor_sig, "--min-catalog-version", "0", floor_cat],
            ["manifest", "catalog", "plan", "--public-key", self.pub1, "--signature", floor_sig, "--current-version", "1", floor_cat, self.v1],
            ["manifest", "catalog", "plan", "--public-key", self.pub1, "--signature", floor_sig, "--target-version", "3", floor_cat, self.v1],
            ["manifest", "catalog", "plan", "--public-key", self.pub1, "--signature", floor_sig, "--current-version", "1", "--target-version", "3", floor_cat],
        ):
            with self.subTest(bad_args=bad_args):
                self.run_cli(bad_args, code=2)

    def test_signed_patch_chain_and_verify_chain_with_key_rotation(self):
        # Sign step 1 with key1, step 2 & target with key2 (live key rotation across a chain!).
        s12 = self.p / "m12.sig"
        s23 = self.p / "m23.sig"
        self.run_cli(["manifest", "sign", "--private-key", self.priv1, self.m12, s12])
        self.run_cli(["manifest", "sign", "--private-key", self.priv2, self.m23, s23])

        # 1. Signed verify-chain succeeds with rotated keys.
        vres = self.run_cli([
            "verify-chain",
            "--target-manifest", self.m23,
            "--public-key", self.pub1, "--public-key", self.pub2,
            "--target-signature", s23,
            "--step-signature", s12,
            "--step-signature", s23,
            self.v1, self.p12, self.m12, self.p23, self.m23,
        ])
        self.assertEqual(
            vres.stdout.strip(),
            b"Chain verification succeeded: signatures and all steps match the supplied manifests.",
        )

        # 2. Signed patch-chain restores v3.bin accurately.
        restored = self.p / "chain-restored.bin"
        self.run_cli([
            "patch-chain",
            "--target-manifest", self.m23,
            "--public-key", self.pub1, "--public-key", self.pub2,
            "--target-signature", s23,
            "--step-signature", s12,
            "--step-signature", s23,
            self.v1, restored, self.p12, self.m12, self.p23, self.m23,
        ])
        self.assertEqual(restored.read_bytes(), self.v3_bytes)

        # 3. Wrong key / tampered step signature / tampered target signature fail BEFORE opening missing inputs.
        missing_old = self.p / "missing-old.bin"
        missing_p1 = self.p / "missing-p1.patch"
        missing_p2 = self.p / "missing-p2.patch"
        bad_out = self.p / "never-created.bin"

        err_key = self.run_cli([
            "patch-chain",
            "--target-manifest", self.m23,
            "--public-key", self.pub1,  # missing pub2!
            "--target-signature", s23,
            "--step-signature", s12,
            "--step-signature", s23,
            missing_old, bad_out, missing_p1, self.m12, missing_p2, self.m23,
        ], code=1).stderr
        self.assertIn(b"key_id mismatch", err_key)
        self.assertNotIn(b"open old input", err_key)
        self.assertFalse(bad_out.exists())

        # Tampered step 2 signature fails before opening inputs.
        sig_obj = json.loads(s23.read_bytes())
        bad_s23 = self.p / "bad-s23.sig"
        flipped = ("0" if sig_obj["signature"][0] != "0" else "1") + sig_obj["signature"][1:]
        bad_s23.write_text(json.dumps(dict(sig_obj, signature=flipped)), encoding="utf-8")

        err_step = self.run_cli([
            "verify-chain",
            "--target-manifest", self.m23,
            "--public-key", self.pub1, "--public-key", self.pub2,
            "--target-signature", s23,
            "--step-signature", s12,
            "--step-signature", bad_s23,
            missing_old, missing_p1, self.m12, missing_p2, self.m23,
        ], code=1).stderr
        self.assertTrue(b"signature" in err_step or b"verification failed" in err_step, err_step)
        self.assertNotIn(b"open old input", err_step)

        # Output aliasing a signature or public key file is refused.
        for alias in (self.pub1, s12, s23):
            self.run_cli([
                "patch-chain",
                "--target-manifest", self.m23,
                "--public-key", self.pub1, "--public-key", self.pub2,
                "--target-signature", s23,
                "--step-signature", s12,
                "--step-signature", s23,
                self.v1, alias, self.p12, self.m12, self.p23, self.m23,
            ], code=1)

        # 4. Incomplete signature arguments fail closed with exit 2.
        incomplete_rows = [
            [
                "patch-chain", "--target-manifest", self.m23,
                "--public-key", self.pub1,
                self.v1, bad_out, self.p12, self.m12, self.p23, self.m23,
            ],
            [
                "patch-chain", "--target-manifest", self.m23,
                "--public-key", self.pub1, "--target-signature", s23,
                self.v1, bad_out, self.p12, self.m12, self.p23, self.m23,
            ],
            [
                "patch-chain", "--target-manifest", self.m23,
                "--public-key", self.pub1, "--target-signature", s23,
                "--step-signature", s12,  # only 1 for 2 steps!
                self.v1, bad_out, self.p12, self.m12, self.p23, self.m23,
            ],
            [
                "verify-chain", "--target-manifest", self.m23,
                "--public-key", self.pub1, "--target-signature", s23,
                "--step-signature", s12, "--step-signature", s23, "--step-signature", s23,  # 3 for 2 steps!
                self.v1, self.p12, self.m12, self.p23, self.m23,
            ],
            [
                "verify-chain", "--target-manifest", self.m23,
                "--target-signature", s23,
                self.v1, self.p12, self.m12,
            ],
            [
                "verify-chain", "--target-manifest", self.m23,
                "--step-signature", s12,
                self.v1, self.p12, self.m12,
            ],
        ]
        for argv in incomplete_rows:
            with self.subTest(argv=argv):
                self.run_cli(argv, code=2)
                self.assertFalse(bad_out.exists())

    def test_regressions_signed_chain_preflight_key_cap_and_old_limit(self):
        # 1. Signed patch-chain verifies target & step signatures BEFORE checking OLD/PATCH parents.
        s12 = self.p / "reg-m12.sig"
        s23 = self.p / "reg-m23.sig"
        self.run_cli(["manifest", "sign", "--private-key", self.priv1, self.m12, s12])
        self.run_cli(["manifest", "sign", "--private-key", self.priv2, self.m23, s23])

        missing_old = self.p / "nonexistent_old_parent" / "old.bin"
        missing_p1 = self.p / "nonexistent_p1_parent" / "p1.patch"
        missing_p2 = self.p / "nonexistent_p2_parent" / "p2.patch"
        bad_out = self.p / "reg-chain-out.bin"

        err_sig_first = self.run_cli([
            "patch-chain",
            "--target-manifest", self.m23,
            "--public-key", self.pub1,  # missing pub2 for target & step 2!
            "--target-signature", s23,
            "--step-signature", s12,
            "--step-signature", s23,
            missing_old, bad_out, missing_p1, self.m12, missing_p2, self.m23,
        ], code=1).stderr
        self.assertIn(b"key_id mismatch", err_sig_first)
        self.assertNotIn(b"open output pair parent", err_sig_first)
        self.assertFalse(bad_out.exists())

        # Tampered step signature also fails BEFORE checking missing step patch parent.
        sig_obj = json.loads(s23.read_bytes())
        bad_s23 = self.p / "reg-bad-s23.sig"
        flipped = ("0" if sig_obj["signature"][0] != "0" else "1") + sig_obj["signature"][1:]
        bad_s23.write_text(json.dumps(dict(sig_obj, signature=flipped)), encoding="utf-8")
        err_step_first = self.run_cli([
            "patch-chain",
            "--target-manifest", self.m23,
            "--public-key", self.pub1, "--public-key", self.pub2,
            "--target-signature", s23,
            "--step-signature", s12,
            "--step-signature", bad_s23,
            missing_old, bad_out, missing_p1, self.m12, missing_p2, self.m23,
        ], code=1).stderr
        self.assertTrue(b"signature" in err_step_first or b"verification failed" in err_step_first, err_step_first)
        self.assertNotIn(b"open output pair parent", err_step_first)
        self.assertFalse(bad_out.exists())

        # 2. Streaming key read error does not append duplicate OS error string.
        missing_key = self.p / "no-such-key.pub"
        err_stream_key = self.run_cli([
            "patch", "--stream", "--manifest", self.m12,
            "--public-key", missing_key, "--signature", s12,
            self.v1, self.p12, bad_out,
        ], code=1).stderr.decode("utf-8", errors="replace")
        self.assertEqual(err_stream_key.count("open input"), 1, err_stream_key)
        self.assertFalse(bad_out.exists())

        # 3. manifest catalog plan labels CURRENT_FILE size cap as max_old_bytes (not "full target").
        cat_sig = self.p / "reg-cat.sig"
        self.run_cli(["manifest", "catalog", "sign", "--private-key", self.priv1, self.catalog, cat_sig])
        err_old_cap = self.run_cli([
            "manifest", "catalog", "plan",
            "--public-key", self.pub1, "--signature", cat_sig,
            "--current-version", "1", "--target-version", "3",
            "--max-old-bytes", "100",
            self.catalog, self.v1,
        ], code=1).stderr
        self.assertIn(b"max_old_bytes", err_old_cap)
        self.assertNotIn(b"full target", err_old_cap)

        # 4. Duplicate --public-key works and exceeding 64 --public-key flags exits 2.
        self.run_cli([
            "manifest", "catalog", "verify",
            "--public-key", self.pub1, "--public-key", self.pub1,
            "--signature", cat_sig,
            self.catalog,
        ])
        too_many = ["manifest", "catalog", "verify"]
        for _ in range(65):
            too_many.extend(["--public-key", self.pub1])
        too_many.extend(["--signature", cat_sig, self.catalog])
        err_cap = self.run_cli(too_many, code=2).stderr
        self.assertIn(b"at most 64 times", err_cap)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(CatalogAndSignedChainCli)
    )
    if not result.wasSuccessful() or result.testsRun != 5 or result.skipped:
        raise SystemExit(1)
