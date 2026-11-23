"""Real native CLI tests for detached Ed25519 manifest signing and verification."""

import argparse
import contextlib
import ctypes
import getpass
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

from build_cli import ROOT

EXE = None
SIGNED_VERIFY_SUCCESS = b"Verification succeeded: signature, manifest, inputs and restored content match."
UNSIGNED_VERIFY_SUCCESS = b"Verification succeeded: manifest, inputs and restored content match (not publisher authentication)."


class SignatureCli(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="moonbsdiff-sig-")
        self.addCleanup(self.temp.cleanup)
        self.p = Path(self.temp.name)
        self.old = self.p / "old.bin"
        self.new = self.p / "new.bin"
        self.patch = self.p / "patch.bin"
        self.manifest = self.p / "update.json"
        self.out = self.p / "restored.bin"
        self.priv = self.p / "publisher.key"
        self.pub = self.p / "publisher.pub"
        self.sig = self.p / "update.sig"
        # >8 KiB target ensures multi-chunk streaming paths are exercised.
        old_data = (bytes(range(256)) * 36)
        new_data = old_data[:4096] + b"SIGNED-UPDATE-PAYLOAD!" + old_data[4120:] + b"\xaa\x55"
        self.old.write_bytes(old_data)
        self.new.write_bytes(new_data)
        self.run_cli(["diff", "--manifest", self.manifest, self.old, self.new, self.patch])

    def run_cli(self, args, code=0, *, cwd=None, allow_stderr=False):
        workdir = self.p if cwd is None else Path(cwd)
        before = {}
        for entry in workdir.iterdir():
            if entry.is_file() and not entry.is_symlink():
                try:
                    before[entry] = (entry.read_bytes(), entry.stat().st_mtime_ns)
                except OSError:
                    pass
        result = subprocess.run(
            [str(EXE), *map(str, args)],
            cwd=workdir,
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
            for path, state in before.items():
                self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), state, str(path))
        elif not allow_stderr:
            self.assertEqual(result.stderr, b"")
        self.assertFalse(list(workdir.glob(".moonbsdiff-*.tmp")))
        self.assertFalse(list(workdir.glob(".moonbsdiff-compat-*")))
        return result

    def keygen(self, priv=None, pub=None, *, json_mode=True, code=0):
        args = ["manifest", "keygen"]
        if json_mode:
            args.append("--json")
        args.extend([priv or self.priv, pub or self.pub])
        return self.run_cli(args, code)

    def sign(self, priv=None, manifest=None, sig=None, *, json_mode=True, code=0):
        args = ["manifest", "sign"]
        if json_mode:
            args.append("--json")
        args.extend(["--private-key", priv or self.priv, manifest or self.manifest, sig or self.sig])
        return self.run_cli(args, code)

    def verify_sig(self, pub=None, sig=None, manifest=None, *, json_mode=True, code=0):
        args = ["manifest", "verify-sig"]
        if json_mode:
            args.append("--json")
        args.extend([
            "--public-key",
            pub or self.pub,
            "--signature",
            sig or self.sig,
            manifest or self.manifest,
        ])
        return self.run_cli(args, code)

    def test_keygen_outputs_permissions_conflicts_and_partial_delivery(self):
        # Text mode keygen.
        text_priv = self.p / "text.key"
        text_pub = self.p / "text.pub"
        res_text = self.keygen(text_priv, text_pub, json_mode=False)
        text_priv_doc = json.loads(text_priv.read_bytes())
        text_pub_doc = json.loads(text_pub.read_bytes())
        text_seed = text_priv_doc["seed"]
        self.assertRegex(text_seed, r"^[0-9a-f]{64}$")
        self.assertNotIn(text_seed.encode("ascii"), res_text.stdout)
        self.assertNotIn(text_seed.encode("ascii"), res_text.stderr)
        self.assertIn(text_pub_doc["key_id"].encode("ascii"), res_text.stdout)
        self.assertIn(str(text_priv).encode("utf-8"), res_text.stdout)
        self.assertIn(str(text_pub).encode("utf-8"), res_text.stdout)

        # JSON mode keygen.
        res_json = self.keygen(json_mode=True)
        meta = json.loads(res_json.stdout)
        priv_doc = json.loads(self.priv.read_bytes())
        pub_doc = json.loads(self.pub.read_bytes())
        expected_key_id = hashlib.sha256(bytes.fromhex(pub_doc["public_key"])).hexdigest()[:16]
        self.assertEqual(priv_doc["schema_version"], 1)
        self.assertEqual(priv_doc["format"], "moonbsdiff-ed25519-private-key")
        self.assertEqual(priv_doc["algorithm"], "ed25519")
        self.assertRegex(priv_doc["seed"], r"^[0-9a-f]{64}$")
        self.assertEqual(priv_doc["public_key"], pub_doc["public_key"])
        self.assertEqual(priv_doc["key_id"], expected_key_id)
        self.assertEqual(pub_doc, {
            "schema_version": 1,
            "format": "moonbsdiff-ed25519-public-key",
            "algorithm": "ed25519",
            "public_key": priv_doc["public_key"],
            "key_id": expected_key_id,
        })
        self.assertEqual(meta, {
            "schema_version": 1,
            "algorithm": "ed25519",
            "key_id": expected_key_id,
            "public_key": pub_doc["public_key"],
            "private_key_path": str(self.priv),
            "public_key_path": str(self.pub),
        })
        self.assertNotEqual(priv_doc["seed"], text_seed)
        self.assertNotIn("seed", meta)
        self.assertNotIn(priv_doc["seed"].encode("ascii"), res_json.stdout)
        self.assertNotIn(priv_doc["seed"].encode("ascii"), res_json.stderr)

        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(self.priv.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(text_priv.stat().st_mode), 0o600)
        else:
            fs_flags = ctypes.c_uint32(0)
            fs_name = ctypes.create_unicode_buffer(64)
            anchor = str(self.priv.resolve().anchor)
            has_acls = (
                bool(anchor)
                and bool(
                    ctypes.windll.kernel32.GetVolumeInformationW(
                        anchor, None, 0, None, None, ctypes.byref(fs_flags), fs_name, len(fs_name)
                    )
                )
                and (fs_flags.value & 0x00000008) != 0
                and fs_name.value.upper() in ("NTFS", "REFS")
            )
            if has_acls:
                current_user = getpass.getuser().lower()
                for key_path in (self.priv, text_priv):
                    try:
                        acl = subprocess.run(["icacls", str(key_path)], capture_output=True, timeout=15)
                    except OSError:
                        continue
                    if acl.returncode != 0:
                        continue
                    acl_text = acl.stdout.decode("mbcs", errors="replace")
                    prefix = str(key_path)
                    aces = []
                    for idx, line in enumerate(acl_text.splitlines()):
                        if not line.strip():
                            break
                        if idx == 0 and line.lower().startswith(prefix.lower()):
                            rest = line[len(prefix):].strip()
                            if rest:
                                aces.append(rest)
                        else:
                            aces.append(line.strip())
                    self.assertEqual(len(aces), 1, acl_text)
                    self.assertNotIn("(I)", aces[0], acl_text)
                    self.assertTrue(aces[0].endswith(":(F)"), acl_text)
                    principal = aces[0].rsplit(":", 1)[0].lower()
                    self.assertTrue(
                        principal == current_user or principal.endswith("\\" + current_user),
                        f"unexpected private key ACL principal {principal!r} for user {current_user!r}",
                    )

        # No-overwrite when either private or public key target exists.
        fresh_priv = self.p / "fresh.key"
        fresh_pub = self.p / "fresh.pub"
        self.keygen(self.priv, fresh_pub, code=1)
        self.assertFalse(fresh_pub.exists())
        self.keygen(fresh_priv, self.pub, code=1)
        self.assertFalse(fresh_priv.exists())

        # Self-alias refused without creating either key.
        alias_sub = self.p / "sub"
        alias_sub.mkdir()
        self.keygen(fresh_priv, fresh_priv, code=1)
        self.keygen(fresh_priv, alias_sub / ".." / "fresh.key", code=1)
        self.assertFalse(fresh_priv.exists())

        # Trailing partial delivery when public key directory refuses writes after private key succeeds.
        locked = self.p / "locked"
        locked.mkdir()
        partial_priv = self.p / "partial.key"
        partial_pub = locked / "partial.pub"
        locked_ready = False
        user = None
        if os.name == "nt":
            user = os.environ.get("USERDOMAIN", "") + "\\" + getpass.getuser()
            acl = subprocess.run(["icacls", str(locked), "/deny", user + ":(WD,AD)"], capture_output=True)
            locked_ready = acl.returncode == 0
        else:
            locked.chmod(0o500)
            locked_ready = True
        if locked_ready:
            try:
                can_probe = False
                try:
                    (locked / "probe").write_bytes(b"x")
                    (locked / "probe").unlink()
                    can_probe = True
                except PermissionError:
                    can_probe = False
                if not can_probe:
                    err = self.run_cli(["manifest", "keygen", partial_priv, partial_pub], code=1).stderr
                    self.assertIn(b"private key delivered", err)
                    self.assertIn(b"no rollback attempted", err)
                    self.assertTrue(partial_priv.is_file())
                    self.assertFalse(partial_pub.exists())
                    self.assertEqual(list(locked.iterdir()), [])
            finally:
                if os.name == "nt":
                    subprocess.run(["icacls", str(locked), "/remove:d", user], capture_output=True, check=True)
                else:
                    locked.chmod(0o700)

    def test_sign_validation_no_overwrite_and_dash_paths(self):
        self.keygen()
        priv_raw = self.priv.read_bytes()
        priv_seed = json.loads(priv_raw)["seed"]

        # Text and JSON sign.
        res_text = self.sign(json_mode=False)
        self.assertIn(b"Manifest signed: algorithm ed25519", res_text.stdout)
        self.assertNotIn(priv_seed.encode("ascii"), res_text.stdout)
        self.assertNotIn(priv_seed.encode("ascii"), res_text.stderr)
        sig_doc = json.loads(self.sig.read_bytes())
        expected_hash = hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.assertEqual(sig_doc["schema_version"], 1)
        self.assertEqual(sig_doc["format"], "moonbsdiff-manifest-signature")
        self.assertEqual(sig_doc["algorithm"], "ed25519")
        self.assertEqual(sig_doc["key_id"], json.loads(self.pub.read_bytes())["key_id"])
        self.assertEqual(sig_doc["manifest_sha256"], expected_hash)
        self.assertRegex(sig_doc["signature"], r"^[0-9a-f]{128}$")

        # No-overwrite on existing signature.
        self.sign(code=1)

        sig_json = self.p / "second.sig"
        res_json = self.sign(sig=sig_json, json_mode=True)
        sign_meta = json.loads(res_json.stdout)
        self.assertEqual(sign_meta, {
            "schema_version": 1,
            "algorithm": "ed25519",
            "key_id": sig_doc["key_id"],
            "manifest_sha256": expected_hash,
            "manifest_path": str(self.manifest),
            "signature_path": str(sig_json),
        })
        self.assertEqual(sig_json.read_bytes(), self.sig.read_bytes())

        # Corrupt/non-manifest/oversized JSON refused.
        bad_manifest = self.p / "not-manifest.json"
        for payload in (b"{}", b"[]", b"{bad", b"\xef\xbb\xbf" + self.manifest.read_bytes(), b" " * 16385):
            bad_manifest.write_bytes(payload)
            out_sig = self.p / "bad-manifest.sig"
            self.sign(manifest=bad_manifest, sig=out_sig, code=1)
            self.assertFalse(out_sig.exists())

        # Oversized / empty / wrong-format / mismatched public_key in private key refused.
        bad_key = self.p / "bad.key"
        priv_obj = json.loads(priv_raw)
        mismatched = dict(priv_obj, public_key=("0" * 64 if priv_obj["public_key"] != "0" * 64 else "1" * 64))
        bad_cases = [
            b"",
            b" " * 4097,
            self.pub.read_bytes(),
            json.dumps(mismatched).encode("utf-8"),
        ]
        for payload in bad_cases:
            bad_key.write_bytes(payload)
            out_sig = self.p / "bad-key.sig"
            self.sign(priv=bad_key, sig=out_sig, code=1)
            self.assertFalse(out_sig.exists())

        # Aliasing output to private key or manifest fails.
        self.sign(sig=self.priv, code=1)
        self.sign(sig=self.manifest, code=1)

        # Leading '-' paths with ./ and -- separator.
        dash_priv = self.p / "-priv.key"
        dash_manifest = self.p / "-manifest.json"
        dash_sig = self.p / "-out.sig"
        dash_priv.write_bytes(priv_raw)
        dash_manifest.write_bytes(self.manifest.read_bytes())
        with contextlib.chdir(self.p):
            self.run_cli(["manifest", "sign", "--private-key", "-priv.key", "--", "-manifest.json", "-out.sig"], code=2)
            self.run_cli(["manifest", "sign", "--private-key", "./-priv.key", "-manifest.json", "-out.sig"], code=2)
            self.run_cli(["manifest", "sign", "--private-key", "./-priv.key", "--", "-manifest.json", "-out.sig"], code=0)
        self.assertEqual(dash_sig.read_bytes(), self.sig.read_bytes())

    def test_verify_sig_valid_and_adversarial_rejections(self):
        self.keygen()
        self.sign()
        manifest_hash = hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        key_id = json.loads(self.pub.read_bytes())["key_id"]

        res_text = self.verify_sig(json_mode=False)
        self.assertEqual(
            res_text.stdout.rstrip(b"\r\n"),
            f"Manifest signature verified: algorithm ed25519, key_id {key_id}, manifest_sha256 {manifest_hash}".encode("ascii"),
        )
        res_json = self.verify_sig(json_mode=True)
        self.assertEqual(json.loads(res_json.stdout), {
            "schema_version": 1,
            "valid": True,
            "algorithm": "ed25519",
            "key_id": key_id,
            "manifest_sha256": manifest_hash,
            "manifest_path": str(self.manifest),
            "public_key_path": str(self.pub),
            "signature_path": str(self.sig),
        })

        # Tampered or oversized manifest (trailing space, flipped byte, >16384 bytes).
        tampered = self.p / "tampered.json"
        raw_manifest = self.manifest.read_bytes()
        tampered.write_bytes(raw_manifest + b" ")
        self.verify_sig(manifest=tampered, code=1)
        tampered.write_bytes(bytes([raw_manifest[0] ^ 1]) + raw_manifest[1:])
        self.verify_sig(manifest=tampered, code=1)
        tampered.write_bytes(b" " * 16385)
        self.verify_sig(manifest=tampered, code=1)

        # Tampered signature hex.
        sig_obj = json.loads(self.sig.read_bytes())
        bad_sig = self.p / "bad.sig"
        flipped_sig = ("0" if sig_obj["signature"][0] != "0" else "1") + sig_obj["signature"][1:]
        bad_sig.write_text(json.dumps(dict(sig_obj, signature=flipped_sig)), encoding="utf-8")
        self.verify_sig(sig=bad_sig, code=1)

        # Wrong public key (KeyIdMismatch).
        other_priv = self.p / "other.key"
        other_pub = self.p / "other.pub"
        self.keygen(other_priv, other_pub)
        err = self.verify_sig(pub=other_pub, code=1).stderr
        self.assertIn(b"key_id mismatch", err)

        # Malformed, BOM, duplicate-key, oversized key and signature files.
        pub_raw = self.pub.read_bytes()
        sig_raw = self.sig.read_bytes()
        for bad_bytes in (
            b"\xef\xbb\xbf" + pub_raw,
            pub_raw.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1'),
            b" " * 4097,
            b"{invalid",
        ):
            bad_pub = self.p / "bad.pub"
            bad_pub.write_bytes(bad_bytes)
            self.verify_sig(pub=bad_pub, code=1)

        for bad_bytes in (
            b"\xef\xbb\xbf" + sig_raw,
            sig_raw.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1'),
            b" " * 4097,
            b"{invalid",
        ):
            bad_sig.write_bytes(bad_bytes)
            self.verify_sig(sig=bad_sig, code=1)

        # Missing required flags exit 2.
        for args in (
            ["manifest", "verify-sig", self.manifest],
            ["manifest", "verify-sig", "--public-key", self.pub, self.manifest],
            ["manifest", "verify-sig", "--signature", self.sig, self.manifest],
            ["manifest", "verify-sig", "--public-key", self.pub, "--signature", self.sig],
            ["manifest", "verify-sig", "--public-key", self.pub, "--signature", self.sig, self.manifest, self.manifest],
        ):
            self.run_cli(args, code=2)

    def test_signed_verify_patch_and_install_full(self):
        self.keygen()
        self.sign()
        expected_new = self.new.read_bytes()

        # Unsigned vs signed verify stdout lines differ clearly.
        unsigned_res = self.run_cli(["verify", "--manifest", self.manifest, self.old, self.patch])
        self.assertEqual(unsigned_res.stdout.rstrip(b"\r\n"), UNSIGNED_VERIFY_SUCCESS)
        for stream_flag in ([], ["--stream"]):
            res = self.run_cli([
                "verify", *stream_flag, "--manifest", self.manifest,
                "--public-key", self.pub, "--signature", self.sig,
                self.old, self.patch,
            ])
            self.assertEqual(res.stdout.rstrip(b"\r\n"), SIGNED_VERIFY_SUCCESS)

        # Signed patch (memory and --stream).
        mem_out = self.p / "signed-mem.bin"
        stream_out = self.p / "signed-stream.bin"
        self.run_cli([
            "patch", "--manifest", self.manifest,
            "--public-key", self.pub, "--signature", self.sig,
            self.old, self.patch, mem_out,
        ])
        self.assertEqual(mem_out.read_bytes(), expected_new)

        stream_res = self.run_cli([
            "patch", "--stream", "--progress", "json", "--manifest", self.manifest,
            "--public-key", self.pub, "--signature", self.sig,
            self.old, self.patch, stream_out,
        ], allow_stderr=True)
        self.assertEqual(stream_res.stdout, b"")
        self.assertEqual(stream_out.read_bytes(), expected_new)
        rows = [json.loads(line) for line in stream_res.stderr.decode("utf-8").splitlines()]
        self.assertEqual(rows[-1]["event"], "complete")
        self.assertTrue(rows[-1]["output_committed"])

        # Signed install-full.
        full_out = self.p / "signed-full.bin"
        self.run_cli([
            "install-full", "--target-manifest", self.manifest,
            "--public-key", self.pub, "--signature", self.sig,
            self.new, full_out,
        ])
        self.assertEqual(full_out.read_bytes(), expected_new)

        # Wrong key, tampered signature, tampered manifest fail BEFORE opening inputs or creating output.
        other_priv = self.p / "other.key"
        other_pub = self.p / "other.pub"
        self.keygen(other_priv, other_pub)
        tampered_manifest = self.p / "tampered.json"
        tampered_manifest.write_bytes(self.manifest.read_bytes() + b" ")
        bad_sig = self.p / "bad.sig"
        sig_obj = json.loads(self.sig.read_bytes())
        flipped = ("0" if sig_obj["signature"][0] != "0" else "1") + sig_obj["signature"][1:]
        bad_sig.write_text(json.dumps(dict(sig_obj, signature=flipped)), encoding="utf-8")

        missing_old = self.p / "missing-old.bin"
        missing_patch = self.p / "missing-patch.bin"
        missing_dl = self.p / "missing-dl.bin"

        for bad_label, pub_arg, sig_arg, man_arg, expected_diag in (
            ("wrong-key", other_pub, self.sig, self.manifest, b"key_id mismatch"),
            ("tampered-sig", self.pub, bad_sig, self.manifest, b"signature"),
            ("tampered-manifest", self.pub, self.sig, tampered_manifest, b"manifest_sha256 mismatch"),
        ):
            with self.subTest(case=bad_label):
                for cmd in (
                    ["verify", "--manifest", man_arg, "--public-key", pub_arg, "--signature", sig_arg, missing_old, missing_patch],
                    ["verify", "--stream", "--manifest", man_arg, "--public-key", pub_arg, "--signature", sig_arg, missing_old, missing_patch],
                    ["patch", "--manifest", man_arg, "--public-key", pub_arg, "--signature", sig_arg, missing_old, missing_patch, self.out],
                    ["patch", "--stream", "--manifest", man_arg, "--public-key", pub_arg, "--signature", sig_arg, missing_old, missing_patch, self.out],
                    ["install-full", "--target-manifest", man_arg, "--public-key", pub_arg, "--signature", sig_arg, missing_dl, self.out],
                ):
                    err = self.run_cli(cmd, code=1).stderr
                    self.assertFalse(self.out.exists())
                    self.assertNotIn(b"open input", err)
                    self.assertNotIn(b"open/size stream input", err)
                    self.assertNotIn(b"open downloaded file", err)
                    self.assertIn(expected_diag, err)
                    self.assertTrue(
                        any(token in err for token in (b"mismatch", b"signature", b"Ed25519")),
                        err.decode("utf-8", errors="replace"),
                    )

        # Output aliasing --public-key or --signature is refused without overwriting either file.
        for alias in (self.pub, self.sig):
            self.run_cli([
                "patch", "--manifest", self.manifest,
                "--public-key", self.pub, "--signature", self.sig,
                self.old, self.patch, alias,
            ], code=1)
            self.run_cli([
                "patch", "--stream", "--manifest", self.manifest,
                "--public-key", self.pub, "--signature", self.sig,
                self.old, self.patch, alias,
            ], code=1)
            self.run_cli([
                "install-full", "--target-manifest", self.manifest,
                "--public-key", self.pub, "--signature", self.sig,
                self.new, alias,
            ], code=1)

        # Invalid CLI flag combinations exit 2 without touching disk.
        invalid_calls = [
            ["verify", "--manifest", self.manifest, "--public-key", self.pub, self.old, self.patch],
            ["verify", "--manifest", self.manifest, "--signature", self.sig, self.old, self.patch],
            ["verify", "--stream", "--manifest", self.manifest, "--public-key", self.pub, self.old, self.patch],
            ["verify", "--stream", "--manifest", self.manifest, "--signature", self.sig, self.old, self.patch],
            ["patch", "--manifest", self.manifest, "--public-key", self.pub, self.old, self.patch, self.out],
            ["patch", "--manifest", self.manifest, "--signature", self.sig, self.old, self.patch, self.out],
            ["patch", "--public-key", self.pub, "--signature", self.sig, self.old, self.patch, self.out],
            ["patch", "--stream", "--public-key", self.pub, "--signature", self.sig, self.old, self.patch, self.out],
            ["install-full", "--target-manifest", self.manifest, "--public-key", self.pub, self.new, self.out],
            ["install-full", "--target-manifest", self.manifest, "--signature", self.sig, self.new, self.out],
            ["verify", "--private-key", self.priv, "--manifest", self.manifest, self.old, self.patch],
            ["patch", "--private-key", self.priv, "--manifest", self.manifest, self.old, self.patch, self.out],
            ["install-full", "--private-key", self.priv, "--target-manifest", self.manifest, self.new, self.out],
            ["manifest", "keygen", "--private-key", self.priv, self.p / "a", self.p / "b"],
            ["manifest", "verify-sig", "--private-key", self.priv, "--public-key", self.pub, "--signature", self.sig, self.manifest],
            ["diff", "--public-key", self.pub, self.old, self.new, self.p / "x.patch"],
            ["manifest", "create", "--signature", self.sig, self.old, self.new, self.patch, self.p / "x.json"],
            ["manifest", "select", "--public-key", self.pub, self.old, self.manifest],
            ["manifest", "plan", "--public-key", self.pub, "--target-manifest", self.manifest, self.old],
            ["manifest", "keygen", "--public-key", self.pub, self.p / "a", self.p / "b"],
            ["manifest", "sign", "--public-key", self.pub, "--private-key", self.priv, self.manifest, self.p / "x.sig"],
            ["verify", "--json", "--manifest", self.manifest, self.old, self.patch],
            ["patch", "--json", self.old, self.patch, self.out],
            ["install-full", "--json", "--target-manifest", self.manifest, self.new, self.out],
        ]
        for argv in invalid_calls:
            with self.subTest(argv=argv):
                self.run_cli(argv, code=2)
                self.assertFalse(self.out.exists())

    def test_deterministic_verification_failed_cli(self):
        self.keygen()
        self.sign()
        sig_obj = json.loads(self.sig.read_bytes())
        ed25519_l = (1 << 252) + 27742317777372353535851937790883648493
        sig_bytes = bytearray(bytes.fromhex(sig_obj["signature"]))
        orig_s = int.from_bytes(sig_bytes[32:64], "little")
        sig_bytes[32] ^= 1
        if int.from_bytes(sig_bytes[32:64], "little") >= ed25519_l:
            sig_bytes[32:64] = (orig_s - 1).to_bytes(32, "little")
        self.assertLess(int.from_bytes(sig_bytes[32:64], "little"), ed25519_l)
        bad_s_sig = self.p / "bad-s.sig"
        bad_s_sig.write_text(
            json.dumps(dict(sig_obj, signature=sig_bytes.hex())),
            encoding="utf-8",
        )
        expected = b"Ed25519 manifest signature verification failed"
        for json_mode in (False, True):
            res = self.verify_sig(sig=bad_s_sig, json_mode=json_mode, code=1)
            self.assertEqual(res.stdout, b"")
            self.assertIn(expected, res.stderr)
        for stream_flag in ([], ["--stream"]):
            res = self.run_cli(
                [
                    "verify", *stream_flag, "--manifest", self.manifest,
                    "--public-key", self.pub, "--signature", bad_s_sig,
                    self.old, self.patch,
                ],
                code=1,
            )
            self.assertEqual(res.stdout, b"")
            self.assertIn(expected, res.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(SignatureCli)
    )
    if not result.wasSuccessful() or result.testsRun != 5 or result.skipped:
        raise SystemExit(1)
