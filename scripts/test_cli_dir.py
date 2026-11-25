"""Native CLI tests for dir-diff, dir-verify, and dir-patch."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


EXE = None


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def make_added_only_bundle(bundle_dir, file_map):
    """Build a valid schema-1 dir bundle transitioning from an empty OLD_DIR to file_map."""
    bundle_dir.mkdir(parents=True, exist_ok=True)
    blobs_dir = bundle_dir / "blobs"
    blobs_dir.mkdir(exist_ok=True)
    sorted_items = sorted(file_map.items(), key=lambda kv: kv[0].encode("utf-8"))
    tree_lines = []
    entries = []
    total_bytes = 0
    for idx, (rel, data) in enumerate(sorted_items, start=1):
        digest = sha256_hex(data)
        blob_name = f"blob-{idx:04d}.full"
        (blobs_dir / blob_name).write_bytes(data)
        tree_lines.append(f"{digest} {len(data)} {rel}\n")
        total_bytes += len(data)
        entries.append(
            {
                "action": "added",
                "path": rel,
                "identity": {"size_bytes": str(len(data)), "sha256": digest},
                "blob_name": blob_name,
                "full_fallback": False,
            }
        )
    new_tree_hash = sha256_hex("".join(tree_lines).encode("utf-8"))
    manifest = {
        "schema": 1,
        "type": "moonbsdiff-dir-manifest",
        "old_tree_sha256": sha256_hex(b""),
        "new_tree_sha256": new_tree_hash,
        "old_file_count": 0,
        "new_file_count": len(sorted_items),
        "old_total_bytes": "0",
        "new_total_bytes": str(total_bytes),
        "delta_payload_bytes": str(total_bytes),
        "entries": entries,
    }
    (bundle_dir / "dir-manifest.json").write_bytes(
        (json.dumps(manifest, separators=(",", ":")) + "\n").encode("utf-8")
    )


def lcg_bytes(seed, length):
    state = seed & 0xFFFFFFFF
    out = bytearray(length)
    for i in range(length):
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        out[i] = (state >> 24) & 0xFF
    return bytes(out)


def write_tree(root, mapping):
    root.mkdir(parents=True, exist_ok=True)
    for rel, data in mapping.items():
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def read_tree(root):
    out = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            out[path.relative_to(root).as_posix()] = path.read_bytes()
    return out


class DirCli(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonbsdiff-dir-")
        self.addCleanup(self.temp.cleanup)
        self.p = Path(self.temp.name)

        self.old_dir = self.p / "old_tree"
        self.new_dir = self.p / "new_tree"

        same_bytes = lcg_bytes(0x11111111, 512)
        rename_bytes = lcg_bytes(0x22222222, 1024)
        patch_old = lcg_bytes(0x33333333, 4096)
        patch_new = patch_old[:1500] + b"DIR-PATCHED-BLOCK!" + patch_old[1518:]
        fallback_old = b"12345678"
        fallback_new = b"ABCDEFGH"
        added_bytes = b"brand new nested file\x00\xff"
        deleted_bytes = b"obsolete file to remove"

        self.old_files = {
            "keep/same.bin": same_bytes,
            "moved/from.bin": rename_bytes,
            "app/binary.bin": patch_old,
            "tiny/fallback.bin": fallback_old,
            "obsolete/gone.bin": deleted_bytes,
        }
        self.new_files = {
            "keep/same.bin": same_bytes,
            "moved/to/renamed.bin": rename_bytes,
            "app/binary.bin": patch_new,
            "tiny/fallback.bin": fallback_new,
            "fresh/nested/added.bin": added_bytes,
        }
        write_tree(self.old_dir, self.old_files)
        write_tree(self.new_dir, self.new_files)

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

    def test_dir_diff_verify_patch_all_action_types(self):
        bundle = self.p / "bundle"
        diff_res = self.run_cli(["dir-diff", "--json", self.old_dir, self.new_dir, bundle])
        diff_doc = json.loads(diff_res.stdout)
        self.assertEqual(diff_doc["schema_version"], 1)
        self.assertEqual(diff_doc["operation"], "dir-diff")
        self.assertFalse(diff_doc["signed"])
        self.assertIsNone(diff_doc["signer_key_id"])
        self.assertEqual(diff_doc["unchanged_count"], 1)
        self.assertEqual(diff_doc["renamed_count"], 1)
        self.assertEqual(diff_doc["patched_count"], 1)
        self.assertEqual(diff_doc["added_count"], 2)
        self.assertEqual(diff_doc["full_fallback_count"], 1)
        # Both obsolete/gone.bin and the old path of moved/from.bin are recorded as deleted.
        self.assertEqual(diff_doc["deleted_count"], 2)
        self.assertEqual(diff_doc["blob_count"], 3)
        self.assertLess(int(diff_doc["delta_payload_bytes"]), int(diff_doc["new_total_bytes"]))
        self.assertTrue((bundle / "dir-manifest.json").is_file())
        self.assertTrue((bundle / "blobs").is_dir())
        self.assertFalse((bundle / "dir-manifest.sig").exists())

        # dir-verify (JSON and text) creates no files.
        before_entries = set(os.listdir(self.p))
        ver_doc = json.loads(
            self.run_cli(["dir-verify", "--json", self.old_dir, bundle]).stdout
        )
        self.assertTrue(ver_doc["valid"])
        self.assertEqual(ver_doc["unchanged_count"], 1)
        self.assertEqual(ver_doc["renamed_count"], 1)
        self.assertEqual(ver_doc["patched_count"], 1)
        self.assertEqual(ver_doc["added_count"], 2)
        self.assertEqual(ver_doc["full_fallback_count"], 1)
        self.assertEqual(ver_doc["deleted_count"], 2)
        self.assertEqual(ver_doc["old_tree_sha256"], diff_doc["old_tree_sha256"])
        self.assertEqual(ver_doc["new_tree_sha256"], diff_doc["new_tree_sha256"])
        ver_text = self.run_cli(["dir-verify", self.old_dir, bundle]).stdout.decode("utf-8")
        self.assertIn("Directory verification succeeded", ver_text)
        self.assertEqual(set(os.listdir(self.p)), before_entries)

        # dir-patch restores exact new tree byte-for-byte.
        out_dir = self.p / "restored_tree"
        patch_doc = json.loads(
            self.run_cli(["dir-patch", "--json", self.old_dir, bundle, out_dir]).stdout
        )
        self.assertEqual(patch_doc["operation"], "dir-patch")
        self.assertEqual(patch_doc["restored_file_count"], len(self.new_files))
        self.assertEqual(patch_doc["new_tree_sha256"], diff_doc["new_tree_sha256"])
        self.assertEqual(read_tree(out_dir), self.new_files)

        # Zero-blob bundle (unchanged/renamed only, no blobs/ directory).
        only_rename_old = self.p / "ren_old"
        only_rename_new = self.p / "ren_new"
        write_tree(only_rename_old, {"a.bin": b"hello"})
        write_tree(only_rename_new, {"sub/b.bin": b"hello"})
        zero_bundle = self.p / "zero_bundle"
        zdiff = json.loads(
            self.run_cli(["dir-diff", "--json", only_rename_old, only_rename_new, zero_bundle]).stdout
        )
        self.assertEqual(zdiff["blob_count"], 0)
        self.assertEqual(zdiff["delta_payload_bytes"], "0")
        self.assertFalse((zero_bundle / "blobs").exists())
        self.run_cli(["dir-verify", "--json", only_rename_old, zero_bundle])
        zout = self.p / "zero_out"
        self.run_cli(["dir-patch", "--json", only_rename_old, zero_bundle, zout])
        self.assertEqual(read_tree(zout), {"sub/b.bin": b"hello"})

    def test_signed_dir_bundle_with_multi_key_rotation(self):
        priv1, pub1 = self.p / "k1.key", self.p / "k1.pub"
        priv2, pub2 = self.p / "k2.key", self.p / "k2.pub"
        priv3, pub3 = self.p / "k3.key", self.p / "k3.pub"
        k1 = json.loads(self.run_cli(["manifest", "keygen", "--json", priv1, pub1]).stdout)
        self.run_cli(["manifest", "keygen", "--json", priv2, pub2])
        self.run_cli(["manifest", "keygen", "--json", priv3, pub3])

        bundle = self.p / "signed_bundle"
        diff_doc = json.loads(
            self.run_cli([
                "dir-diff", "--private-key", priv1, "--json",
                self.old_dir, self.new_dir, bundle,
            ]).stdout
        )
        self.assertTrue(diff_doc["signed"])
        self.assertEqual(diff_doc["signer_key_id"], k1["key_id"])
        sig_path = bundle / "dir-manifest.sig"
        self.assertTrue(sig_path.is_file())
        self.assertEqual(Path(diff_doc["signature_path"]), sig_path)

        # Verify & patch with rotated trust store [pub2, pub1].
        ver_doc = json.loads(
            self.run_cli([
                "dir-verify",
                "--public-key", pub2, "--public-key", pub1,
                "--signature", sig_path, "--json",
                self.old_dir, bundle,
            ]).stdout
        )
        self.assertTrue(ver_doc["valid"])
        self.assertTrue(ver_doc["signed"])
        self.assertEqual(ver_doc["signer_key_id"], k1["key_id"])

        out_dir = self.p / "signed_restored"
        patch_doc = json.loads(
            self.run_cli([
                "dir-patch",
                "--public-key", pub2, "--public-key", pub1,
                "--signature", sig_path, "--json",
                self.old_dir, bundle, out_dir,
            ]).stdout
        )
        self.assertTrue(patch_doc["signed"])
        self.assertEqual(patch_doc["signer_key_id"], k1["key_id"])
        self.assertEqual(read_tree(out_dir), self.new_files)

        # Untrusted key3 fails closed BEFORE opening missing OLD_DIR and never creates output.
        missing_old = self.p / "no_such_old"
        bad_out = self.p / "should_not_exist"
        err = self.run_cli([
            "dir-patch",
            "--public-key", pub3, "--signature", sig_path,
            missing_old, bundle, bad_out,
        ], code=1).stderr
        self.assertIn(b"key_id mismatch", err)
        self.assertNotIn(b"list old directory", err)
        self.assertFalse(bad_out.exists())

    def test_tampered_bundle_blob_manifest_and_old_dir_rejected(self):
        priv, pub = self.p / "p.key", self.p / "p.pub"
        self.run_cli(["manifest", "keygen", priv, pub])
        bundle = self.p / "t_bundle"
        self.run_cli(["dir-diff", "--private-key", priv, self.old_dir, self.new_dir, bundle])
        sig_path = bundle / "dir-manifest.sig"
        out_dir = self.p / "tamper_out"

        # 1. Tampered blob fails both dir-verify and dir-patch without creating output.
        blob_file = sorted((bundle / "blobs").iterdir())[0]
        orig_blob = blob_file.read_bytes()
        blob_file.write_bytes(orig_blob[:-1] + bytes([orig_blob[-1] ^ 1]))
        self.run_cli(["dir-verify", self.old_dir, bundle], code=1)
        self.run_cli(["dir-patch", self.old_dir, bundle, out_dir], code=1)
        self.assertFalse(out_dir.exists())
        blob_file.write_bytes(orig_blob)

        # 2. Unexpected extra blob rejected.
        extra_blob = bundle / "blobs" / "blob-9999.full"
        extra_blob.write_bytes(b"stray")
        err_extra = self.run_cli(["dir-verify", self.old_dir, bundle], code=1).stderr
        self.assertIn(b"unexpected unreferenced blob", err_extra)
        self.run_cli(["dir-patch", self.old_dir, bundle, out_dir], code=1)
        self.assertFalse(out_dir.exists())
        extra_blob.unlink()

        # 3. Missing required blob rejected.
        blob_file.unlink()
        err_miss = self.run_cli(["dir-verify", self.old_dir, bundle], code=1).stderr
        self.assertIn(b"missing required blob", err_miss)
        blob_file.write_bytes(orig_blob)

        # 4. Tampered manifest rejected on signed verification.
        manifest_file = bundle / "dir-manifest.json"
        orig_manifest = manifest_file.read_bytes()
        manifest_file.write_bytes(orig_manifest + b" ")
        err_man = self.run_cli([
            "dir-verify", "--public-key", pub, "--signature", sig_path,
            self.old_dir, bundle,
        ], code=1).stderr
        self.assertIn(b"manifest_sha256 mismatch", err_man)
        self.run_cli([
            "dir-patch", "--public-key", pub, "--signature", sig_path,
            self.old_dir, bundle, out_dir,
        ], code=1)
        self.assertFalse(out_dir.exists())
        manifest_file.write_bytes(orig_manifest)

        # 5. Tampered old_dir fails old_tree_sha256 check.
        mutated_old = self.p / "mutated_old"
        bad_old_files = dict(self.old_files)
        bad_old_files["keep/same.bin"] = b"corrupted"
        write_tree(mutated_old, bad_old_files)
        err_old = self.run_cli(["dir-patch", mutated_old, bundle, out_dir], code=1).stderr
        self.assertIn(b"old_tree_sha256 mismatch", err_old)
        self.assertFalse(out_dir.exists())

    def test_no_overwrite_and_aliasing_refused(self):
        bundle = self.p / "ok_bundle"
        self.run_cli(["dir-diff", self.old_dir, self.new_dir, bundle])

        # Existing directory or file cannot be overwritten by dir-diff or dir-patch.
        existing_dir = self.p / "existing_dir"
        existing_dir.mkdir()
        sentinel = existing_dir / "keep.txt"
        sentinel.write_bytes(b"preserve-me")
        existing_file = self.p / "existing_file.bin"
        existing_file.write_bytes(b"preserve-file")

        for target in (existing_dir, existing_file, self.old_dir, self.new_dir):
            self.run_cli(["dir-diff", self.old_dir, self.new_dir, target], code=1)
        for target in (existing_dir, existing_file, self.old_dir, bundle):
            self.run_cli(["dir-patch", self.old_dir, bundle, target], code=1)

        self.assertEqual(sentinel.read_bytes(), b"preserve-me")
        self.assertEqual(existing_file.read_bytes(), b"preserve-file")

    def test_symlink_and_reparse_point_rejection(self):
        bundle = self.p / "clean_bundle"
        self.run_cli(["dir-diff", self.old_dir, self.new_dir, bundle])

        if os.name == "nt":
            # Windows directory junctions require no admin privilege and set FILE_ATTRIBUTE_REPARSE_POINT.
            outside = self.p / "outside_secret"
            write_tree(outside, {"secret.txt": b"do-not-read"})

            junc_in_old = self.p / "old_with_junction"
            write_tree(junc_in_old, {"a.bin": b"ok"})
            junc_child = junc_in_old / "link_dir"
            r = subprocess.run(
                ["cmd", "/c", "mklink", "/J", str(junc_child), str(outside)],
                capture_output=True,
            )
            self.assertEqual(r.returncode, 0, r.stderr.decode(errors="replace"))
            try:
                out_bundle = self.p / "junc_bundle"
                err = self.run_cli(["dir-diff", junc_in_old, self.new_dir, out_bundle], code=1).stderr
                self.assertIn(b"reparse point", err)
                self.assertFalse(out_bundle.exists())

                # Junction as root OLD_DIR itself.
                root_junc = self.p / "root_junc"
                r2 = subprocess.run(
                    ["cmd", "/c", "mklink", "/J", str(root_junc), str(self.old_dir)],
                    capture_output=True,
                )
                self.assertEqual(r2.returncode, 0, r2.stderr.decode(errors="replace"))
                try:
                    err2 = self.run_cli(["dir-verify", root_junc, bundle], code=1).stderr
                    self.assertIn(b"reparse point", err2)
                    out_junc = self.p / "out_junc"
                    err3 = self.run_cli(["dir-patch", root_junc, bundle, out_junc], code=1).stderr
                    self.assertIn(b"reparse point", err3)
                    self.assertFalse(out_junc.exists())
                finally:
                    os.rmdir(root_junc)
            finally:
                os.rmdir(junc_child)
        else:
            outside = self.p / "outside_secret"
            outside.mkdir()
            secret = outside / "secret.txt"
            secret.write_bytes(b"do-not-read")

            # 1. File symlink inside OLD_DIR rejected.
            sym_old = self.p / "old_with_sym"
            write_tree(sym_old, {"a.bin": b"ok"})
            (sym_old / "evil.bin").symlink_to(secret)
            out_bundle = self.p / "sym_bundle"
            err = self.run_cli(["dir-diff", sym_old, self.new_dir, out_bundle], code=1).stderr
            self.assertIn(b"symlink", err)
            self.assertFalse(out_bundle.exists())

            # 2. Directory symlink inside NEW_DIR rejected.
            sym_new = self.p / "new_with_dir_sym"
            write_tree(sym_new, {"a.bin": b"ok"})
            (sym_new / "escape").symlink_to(outside, target_is_directory=True)
            err2 = self.run_cli(["dir-diff", self.old_dir, sym_new, out_bundle], code=1).stderr
            self.assertIn(b"symlink", err2)
            self.assertFalse(out_bundle.exists())

            # 3. Symlink as OLD_DIR root (even with trailing '/') rejected.
            root_sym = self.p / "root_sym"
            root_sym.symlink_to(self.old_dir, target_is_directory=True)
            for root_arg in (str(root_sym), str(root_sym) + "/"):
                err3 = self.run_cli(["dir-verify", root_arg, bundle], code=1).stderr
                self.assertIn(b"symlink", err3)

            # 4. Symlink at BUNDLE_DIR/blobs rejected.
            bad_bundle = self.p / "bad_blobs_bundle"
            bad_bundle.mkdir()
            (bad_bundle / "dir-manifest.json").write_bytes((bundle / "dir-manifest.json").read_bytes())
            (bad_bundle / "blobs").symlink_to(bundle / "blobs", target_is_directory=True)
            out_bad = self.p / "out_bad_blobs"
            err4 = self.run_cli(["dir-patch", self.old_dir, bad_bundle, out_bad], code=1).stderr
            self.assertIn(b"symlink", err4)
            self.assertFalse(out_bad.exists())

    def test_invalid_arguments_and_help(self):
        for cmd in ("dir-diff", "dir-verify", "dir-patch"):
            out = self.run_cli([cmd, "--help"]).stdout.decode("utf-8")
            self.assertIn(f"moonbsdiff {cmd}", out)

        pub = self.p / "p.pub"
        sig = self.p / "s.sig"
        pub.write_bytes(b"{}")
        sig.write_bytes(b"{}")

        for bad in (
            ["dir-diff", self.old_dir, self.new_dir],
            ["dir-diff", "--public-key", pub, self.old_dir, self.new_dir, self.p / "b"],
            ["dir-verify", self.old_dir],
            ["dir-verify", "--public-key", pub, self.old_dir, self.p / "b"],
            ["dir-verify", "--signature", sig, self.old_dir, self.p / "b"],
            ["dir-verify", "--private-key", pub, self.old_dir, self.p / "b"],
            ["dir-patch", self.old_dir, self.p / "b"],
            ["dir-patch", "--public-key", pub, self.old_dir, self.p / "b", self.p / "o"],
            ["dir-patch", "--signature", sig, self.old_dir, self.p / "b", self.p / "o"],
        ):
            with self.subTest(bad=bad):
                self.run_cli(bad, code=2)

    def test_nested_output_missing_parent_and_trailing_slash_rejected(self):
        bundle = self.p / "nest_bundle"
        self.run_cli(["dir-diff", self.old_dir, self.new_dir, bundle])

        # 0-blob bundle so bundle/blobs does not yet exist.
        z_old = self.p / "z_old"
        z_new = self.p / "z_new"
        write_tree(z_old, {"x.bin": b"same"})
        write_tree(z_new, {"y.bin": b"same"})
        z_bundle = self.p / "z_bundle"
        self.run_cli(["dir-diff", z_old, z_new, z_bundle])

        # 1. Nested outputs inside input trees are refused without mutating inputs.
        nested_diff_targets = [
            self.old_dir / "bundle_inside_old",
            self.old_dir / "keep" / "deep_bundle",
            self.new_dir / "bundle_inside_new",
        ]
        for target in nested_diff_targets:
            with self.subTest(nested_diff=str(target)):
                err = self.run_cli(["dir-diff", self.old_dir, self.new_dir, target], code=1).stderr
                self.assertIn(b"inside an input directory", err)
                self.assertFalse(target.exists())

        nested_patch_targets = [
            (self.old_dir, bundle, self.old_dir / "out_inside_old"),
            (self.old_dir, bundle, self.old_dir / "keep" / "deep_out"),
            (self.old_dir, bundle, bundle / "out_inside_bundle"),
            (z_old, z_bundle, z_bundle / "blobs"),
        ]
        for old_d, bun_d, target in nested_patch_targets:
            with self.subTest(nested_patch=str(target)):
                err = self.run_cli(["dir-patch", old_d, bun_d, target], code=1).stderr
                self.assertIn(b"inside an input directory", err)
                self.assertFalse(target.exists())

        # 2. Nested output via junction (Windows) or symlink (POSIX) pointing to OLD_DIR or OLD_DIR/keep.
        link_to_old = self.p / "alias_to_old"
        link_to_sub = self.p / "alias_to_sub"
        if os.name == "nt":
            subprocess.run(["cmd", "/c", "mklink", "/J", str(link_to_old), str(self.old_dir)], check=True, capture_output=True)
            subprocess.run(["cmd", "/c", "mklink", "/J", str(link_to_sub), str(self.old_dir / "keep")], check=True, capture_output=True)
        else:
            link_to_old.symlink_to(self.old_dir, target_is_directory=True)
            link_to_sub.symlink_to(self.old_dir / "keep", target_is_directory=True)
        try:
            for alias_target in (link_to_old / "via_alias", link_to_sub / "via_sub_alias"):
                err = self.run_cli(["dir-diff", self.old_dir, self.new_dir, alias_target], code=1).stderr
                self.assertIn(b"inside an input directory", err)
                self.assertFalse(alias_target.exists())
                err2 = self.run_cli(["dir-patch", self.old_dir, bundle, alias_target], code=1).stderr
                self.assertIn(b"inside an input directory", err2)
                self.assertFalse(alias_target.exists())
        finally:
            if os.name == "nt":
                os.rmdir(link_to_old)
                os.rmdir(link_to_sub)
            else:
                link_to_old.unlink()
                link_to_sub.unlink()

        # 3. Missing parent fails fast during preflight (even with nonexistent OLD_DIR).
        missing_old = self.p / "missing_old_dir"
        missing_parent_bundle = self.p / "no_such_parent" / "bundle"
        err_mp1 = self.run_cli(["dir-diff", missing_old, self.new_dir, missing_parent_bundle], code=1).stderr
        self.assertNotIn(b"list old directory", err_mp1)
        self.assertFalse(missing_parent_bundle.exists())

        missing_parent_out = self.p / "no_such_parent" / "out"
        err_mp2 = self.run_cli(["dir-patch", missing_old, bundle, missing_parent_out], code=1).stderr
        self.assertNotIn(b"list old directory", err_mp2)
        self.assertFalse(missing_parent_out.exists())

        # 4. Trailing slash on BUNDLE_DIR / OUTPUT_DIR rejected upfront before reading inputs.
        trail_bundle = str(self.p / "trail_bundle") + "/"
        err_tb = self.run_cli(["dir-diff", missing_old, self.new_dir, trail_bundle], code=1).stderr
        self.assertIn(b"invalid output", err_tb)
        self.assertNotIn(b"list old directory", err_tb)
        self.assertFalse((self.p / "trail_bundle").exists())

        trail_out = str(self.p / "trail_out") + "/"
        err_to = self.run_cli(["dir-patch", missing_old, bundle, trail_out], code=1).stderr
        self.assertIn(b"invalid output", err_to)
        self.assertNotIn(b"list old directory", err_to)
        self.assertFalse((self.p / "trail_out").exists())

    def test_manifest_first_blob_caps_empty_blobs_subdir_and_old_count(self):
        bundle = self.p / "mf_bundle"
        self.run_cli(["dir-diff", self.old_dir, self.new_dir, bundle])

        # 1. Invalid manifest fails BEFORE touching missing OLD_DIR.
        bad_manifest_bundle = self.p / "bad_manifest_bundle"
        bad_manifest_bundle.mkdir()
        (bad_manifest_bundle / "dir-manifest.json").write_bytes(b"{not-json")
        missing_old = self.p / "does_not_exist_old"
        err_badm = self.run_cli(["dir-verify", missing_old, bad_manifest_bundle], code=1).stderr
        self.assertIn(b"dir manifest JSON", err_badm)
        self.assertNotIn(b"list old directory", err_badm)

        # 2. Empty subdirectory inside blobs/ is rejected.
        empty_sub = bundle / "blobs" / "empty_subdir"
        empty_sub.mkdir()
        try:
            err_sub = self.run_cli(["dir-verify", self.old_dir, bundle], code=1).stderr
            self.assertIn(b"unexpected subdirectory", err_sub)
            out_sub = self.p / "out_empty_sub"
            err_sub2 = self.run_cli(["dir-patch", self.old_dir, bundle, out_sub], code=1).stderr
            self.assertIn(b"unexpected subdirectory", err_sub2)
            self.assertFalse(out_sub.exists())
        finally:
            empty_sub.rmdir()

        # 3. Unreferenced oversized blob rejected BEFORE reading blob bytes or missing OLD_DIR.
        stray = bundle / "blobs" / "blob-9999.full"
        stray.write_bytes(b"X" * (2 * 1024 * 1024))
        try:
            err_stray = self.run_cli(["dir-verify", missing_old, bundle], code=1).stderr
            self.assertIn(b"unexpected unreferenced blob", err_stray)
            self.assertNotIn(b"byte limit", err_stray)
            self.assertNotIn(b"list old directory", err_stray)
        finally:
            stray.unlink()

        # 4. Patched blob is capped by exact --max-patch-bytes, NOT max_new_bytes.
        patch_blobs = sorted((bundle / "blobs").glob("*.patch"))
        self.assertTrue(patch_blobs)
        patch_blob = patch_blobs[0]
        orig_patch = patch_blob.read_bytes()
        try:
            patch_blob.write_bytes(b"P" * 2048)
            err_cap = self.run_cli([
                "dir-verify",
                "--max-patch-bytes", "1024",
                "--max-new-bytes", "65536",
                "--max-output-bytes", "65536",
                self.old_dir, bundle,
            ], code=1).stderr
            self.assertIn(b"byte limit 1024 exceeded", err_cap)
        finally:
            patch_blob.write_bytes(orig_patch)

        # 5. old_file_count mismatch rejected cleanly before reading OLD_DIR contents.
        extra_old = self.p / "extra_old"
        extra_files = dict(self.old_files)
        extra_files["extra_untracked.bin"] = b"extra"
        write_tree(extra_old, extra_files)
        err_cnt = self.run_cli(["dir-verify", extra_old, bundle], code=1).stderr
        self.assertIn(b"file count mismatch", err_cnt)

    def test_platform_path_preflight_case_collision_and_windows_paths(self):
        empty_old = self.p / "empty_old"
        empty_old.mkdir()

        # 1. Case-colliding paths in a bundle.
        case_bundle = self.p / "case_bundle"
        make_added_only_bundle(case_bundle, {"Config/a.bin": b"one", "config/a.bin": b"two"})
        case_out = self.p / "case_out"
        if os.name == "nt":
            err_case = self.run_cli(["dir-patch", empty_old, case_bundle, case_out], code=1).stderr
            self.assertIn(b"case-insensitive", err_case)
            self.assertFalse(case_out.exists())
        else:
            # Verify works on POSIX regardless; patch succeeds on case-sensitive FS or fails cleanly before mkdir on CI FS.
            self.run_cli(["dir-verify", empty_old, case_bundle])

        # File vs directory prefix case collision (Foo vs foo/bar.bin).
        prefix_case_bundle = self.p / "prefix_case_bundle"
        make_added_only_bundle(prefix_case_bundle, {"Foo": b"file", "foo/bar.bin": b"nested"})
        prefix_case_out = self.p / "prefix_case_out"
        if os.name == "nt":
            err_pcase = self.run_cli(["dir-patch", empty_old, prefix_case_bundle, prefix_case_out], code=1).stderr
            self.assertIn(b"case-insensitive", err_pcase)
            self.assertFalse(prefix_case_out.exists())

        if os.name == "nt":
            # 2. Windows-unsafe segments rejected BEFORE creating OUTPUT_DIR.
            unsafe_cases = [
                ("colon", {"sub/a:b": b"x"}),
                ("trailing_dot", {"dir./a.bin": b"x"}),
                ("trailing_space", {"sub/file ": b"x"}),
                ("dos_con", {"sub/CON.txt": b"x"}),
                ("dos_nul", {"nul/a.bin": b"x"}),
                ("dos_com1", {"sub/com1": b"x"}),
            ]
            for label, mapping in unsafe_cases:
                with self.subTest(win_unsafe=label):
                    ub = self.p / f"win_unsafe_{label}_bundle"
                    uo = self.p / f"win_unsafe_{label}_out"
                    make_added_only_bundle(ub, mapping)
                    err_u = self.run_cli(["dir-patch", empty_old, ub, uo], code=1).stderr
                    self.assertIn(b"unsafe Windows path segment", err_u)
                    self.assertFalse(uo.exists())

            # 3. Windows extended-length (\\?\) paths work end-to-end for dir-diff / dir-verify / dir-patch.
            ext_prefix = "\\\\?\\"
            ext_old = ext_prefix + str(self.old_dir.resolve())
            ext_new = ext_prefix + str(self.new_dir.resolve())
            ext_bundle_path = self.p / "ext_bundle"
            ext_bundle = ext_prefix + str(ext_bundle_path.resolve())
            ext_out_path = self.p / "ext_out"
            ext_out = ext_prefix + str(ext_out_path.resolve())
            self.run_cli(["dir-diff", "--json", ext_old, ext_new, ext_bundle])
            self.run_cli(["dir-verify", "--json", ext_old, ext_bundle])
            self.run_cli(["dir-patch", "--json", ext_old, ext_bundle, ext_out])
            self.assertEqual(read_tree(ext_out_path), self.new_files)

            # 4. Bare drive-relative path (e.g. "C:") rejected cleanly.
            err_drive = self.run_cli(["dir-diff", "C:", self.new_dir, self.p / "drive_b"], code=1).stderr
            self.assertIn(b"bare drive", err_drive)
            self.assertFalse((self.p / "drive_b").exists())

    def test_duplicate_conflicting_and_capped_public_keys(self):
        priv1, pub1 = self.p / "dk1.key", self.p / "dk1.pub"
        priv2, pub2 = self.p / "dk2.key", self.p / "dk2.pub"
        k1 = json.loads(self.run_cli(["manifest", "keygen", "--json", priv1, pub1]).stdout)
        k2 = json.loads(self.run_cli(["manifest", "keygen", "--json", priv2, pub2]).stdout)

        bundle = self.p / "dup_key_bundle"
        self.run_cli(["dir-diff", "--private-key", priv1, self.old_dir, self.new_dir, bundle])
        sig_path = bundle / "dir-manifest.sig"

        # 1. Duplicate identical --public-key succeeds cleanly.
        self.run_cli([
            "dir-verify",
            "--public-key", pub1, "--public-key", pub1,
            "--signature", sig_path,
            self.old_dir, bundle,
        ])

        # 2. Duplicate non-matching --public-key does not duplicate key_id in mismatch error.
        err_dup = self.run_cli([
            "dir-verify",
            "--public-key", pub2, "--public-key", pub2,
            "--signature", sig_path,
            self.old_dir, bundle,
        ], code=1).stderr.decode("utf-8")
        self.assertIn("key_id mismatch", err_dup)
        self.assertEqual(err_dup.count(k2["key_id"]), 1, err_dup)

        # 3. Conflicting keys (same key_id, different public_key) rejected.
        pub2_doc = json.loads(pub2.read_bytes())
        bad_conflict = self.p / "conflict.pub"
        bad_conflict.write_text(
            json.dumps(dict(pub2_doc, key_id=k1["key_id"])),
            encoding="utf-8",
        )
        self.run_cli([
            "dir-verify",
            "--public-key", pub1, "--public-key", bad_conflict,
            "--signature", sig_path,
            self.old_dir, bundle,
        ], code=1)

        # 4. Exceeding 64 repeatable --public-key flags exits 2.
        too_many = ["dir-verify"]
        for _ in range(65):
            too_many.extend(["--public-key", pub1])
        too_many.extend(["--signature", sig_path, self.old_dir, bundle])
        err_cap = self.run_cli(too_many, code=2).stderr
        self.assertIn(b"at most 64 times", err_cap)

    def test_redteam_unicode_case_device_namespace_and_trailing_dot_fixes(self):
        empty_old = self.p / "rt_empty_old"
        empty_old.mkdir()

        # Probe whether the temp directory filesystem is case-insensitive (Windows NTFS, macOS APFS, DrvFs).
        probe_lo = self.p / "rt_case_probe_a"
        probe_hi = self.p / "rt_case_probe_A"
        probe_lo.write_bytes(b"1")
        try:
            fs_case_insensitive = (os.name == "nt") or probe_hi.exists()
        finally:
            probe_lo.unlink()

        # 1. Unicode case-collision bundles (dir-dir, file-file, file-dir, Greek, Cyrillic).
        unicode_cases = [
            ("umlaut_dir", {"\u00e4/a.txt": b"AAA", "\u00c4/b.txt": b"BBB"}),
            ("umlaut_file", {"\u00e4.txt": b"AAA", "\u00c4.txt": b"BBB"}),
            ("umlaut_file_dir", {"\u00e4": b"AAA", "\u00c4/x.txt": b"BBB"}),
            ("greek_dir", {"\u03c9/a.txt": b"AAA", "\u03a9/b.txt": b"BBB"}),
            ("cyrillic_file", {"\u0430.bin": b"AAA", "\u0410.bin": b"BBB"}),
        ]
        for label, mapping in unicode_cases:
            with self.subTest(unicode_case=label):
                ub = self.p / f"uc_{label}_bundle"
                uo = self.p / f"uc_{label}_out"
                make_added_only_bundle(ub, mapping)
                if fs_case_insensitive:
                    err = self.run_cli(["dir-patch", empty_old, ub, uo], code=1).stderr
                    self.assertIn(b"case-insensitive", err)
                    self.assertFalse(uo.exists())
                else:
                    self.run_cli(["dir-verify", empty_old, ub])

        if os.name == "nt":
            # 2. Additional DOS device names (COM0, LPT0, CONIN$, CONOUT$, superscript COM¹²³/LPT¹²³).
            extra_dos = [
                ("com0", {"sub/COM0.bin": b"x"}),
                ("lpt0", {"sub/lpt0": b"x"}),
                ("conin", {"sub/CONIN$": b"x"}),
                ("conout", {"sub/conout$.txt": b"x"}),
                ("com_sup1", {"sub/COM\u00b9.txt": b"x"}),
                ("lpt_sup2", {"sub/lpt\u00b2": b"x"}),
                ("lpt_sup3", {"sub/LPT\u00b3.bin": b"x"}),
            ]
            for label, mapping in extra_dos:
                with self.subTest(extra_dos=label):
                    ub = self.p / f"dos_{label}_bundle"
                    uo = self.p / f"dos_{label}_out"
                    make_added_only_bundle(ub, mapping)
                    err = self.run_cli(["dir-patch", empty_old, ub, uo], code=1).stderr
                    self.assertIn(b"unsafe Windows path segment", err)
                    self.assertFalse(uo.exists())

            # 3. Win32 device-namespace (\\.\) outputs are rejected outright without creating anything.
            dev_bad_1 = "\\\\.\\C:/moonbsdiff_must_never_exist"
            dev_bad_2 = "\\\\.\\" + str(self.p.resolve()) + "\\dev_dot."
            for target in (dev_bad_1, dev_bad_2):
                with self.subTest(dev_ns=target):
                    err = self.run_cli(["dir-diff", self.old_dir, self.new_dir, target], code=1).stderr
                    self.assertIn(b"device namespace", err)
            self.assertFalse((self.p / "dev_dot").exists())

            # 4. Non-extended top-level trailing space/dot BUNDLE_DIR and OUTPUT_DIR rejected before mkdir.
            good_bundle = self.p / "rt_good_bundle"
            self.run_cli(["dir-diff", self.old_dir, self.new_dir, good_bundle])
            for name in ("trail_bundle ", "trail_bundle.", "trail_dir /sub", "trail_dir./sub"):
                target = str(self.p.resolve()) + "\\" + name
                with self.subTest(trail_diff=name):
                    err = self.run_cli(["dir-diff", self.old_dir, self.new_dir, target], code=1).stderr
                    self.assertIn(b"trailing dot or space", err)
            self.assertFalse((self.p / "trail_bundle").exists())
            self.assertFalse((self.p / "trail_dir").exists())

            for name in ("trail_out ", "trail_out."):
                target = str(self.p.resolve()) + "\\" + name
                with self.subTest(trail_patch=name):
                    err = self.run_cli(["dir-patch", self.old_dir, good_bundle, target], code=1).stderr
                    self.assertIn(b"trailing dot or space", err)
            self.assertFalse((self.p / "trail_out").exists())

            # 5. Trailing-dot file in OLD_DIR (file vs \\?\...\file.) reads distinct contents, never aliases!
            dot_old = self.p / "dot_old"
            dot_new = self.p / "dot_new"
            dot_old.mkdir()
            dot_new.mkdir()
            content_plain = b"CONTENT_WITHOUT_DOT"
            content_dotted = b"CONTENT_WITH_TRAILING_DOT"
            (dot_old / "file").write_bytes(content_plain)
            ext_dotted = "\\\\?\\" + str((dot_old / "file").resolve()) + "."
            with open(ext_dotted, "wb") as fh:
                fh.write(content_dotted)
            try:
                dot_bundle = self.p / "dot_bundle"
                self.run_cli(["dir-diff", dot_old, dot_new, dot_bundle])
                manifest = json.loads((dot_bundle / "dir-manifest.json").read_bytes())
                by_path = {e["path"]: e["old_identity"] for e in manifest["entries"]}
                self.assertEqual(
                    by_path["file"],
                    {"size_bytes": str(len(content_plain)), "sha256": sha256_hex(content_plain)},
                )
                self.assertEqual(
                    by_path["file."],
                    {"size_bytes": str(len(content_dotted)), "sha256": sha256_hex(content_dotted)},
                )
                self.assertNotEqual(by_path["file"]["sha256"], by_path["file."]["sha256"])
                self.run_cli(["dir-verify", dot_old, dot_bundle])
            finally:
                os.unlink(ext_dotted)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(DirCli)
    )
    if not result.wasSuccessful() or result.testsRun != 11 or result.skipped:
        raise SystemExit(1)
