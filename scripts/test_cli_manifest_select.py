"""Check manifest-only selection and one downstream streamed verification."""

import argparse
import bz2
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_cli import ROOT, version
from test_cli_manifest_create import VERIFY_SUCCESS, identity
from test_cli_stream import envelope, integer


EXE = None
REPLACE = ROOT / "testdata/upstream/replace"


class ManifestSelect(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="moonbsdiff-select-")
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def run_cli(self, args, code=0):
        result = subprocess.run([EXE, *args], cwd=self.folder,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr.decode(errors="replace"))
        if code == 0:
            self.assertEqual(result.stderr, b"")
        else:
            self.assertEqual(result.stdout, b"")
            self.assertTrue(result.stderr)
        return result

    def write(self, name, data):
        (self.folder / name).write_bytes(data)

    def select(self, *paths, code=0, options=()):
        before = {p.name: p.read_bytes() for p in self.folder.iterdir()}
        result = self.run_cli(["manifest", "select", *options, "installed.bin", *paths], code)
        self.assertEqual({p.name: p.read_bytes() for p in self.folder.iterdir()}, before)
        return result

    def candidate(self, path, old, new, patch):
        document = {"schema_version": 1, "patch_format": "BSDIFF40",
                    "producer": {"name": "moonbsdiff", "version": version()},
                    "old": identity(old), "new": identity(new), "patch": identity(patch)}
        self.write(path, json.dumps(document).encode("utf-8"))

    def expected(self, path, patch, new):
        return {"schema_version": 1, "manifest_path": path,
                "patch": identity(patch), "new": identity(new)}

    def test_equal_length_versions_select_by_hash_and_verify(self):
        v1, v2, target = b"ABCDE", b"ABXDE", b"prefix-ABCDE!"
        self.assertEqual(len(v1), len(v2))
        self.assertNotEqual(v1, v2)
        self.write("v1.bin", v1)
        self.write("installed.bin", v2)
        self.write("v3.bin", target)
        self.run_cli(["diff", "--manifest", "v1-to-v3.json", "v1.bin", "v3.bin", "v1.download"])
        self.run_cli(["diff", "--manifest", "v2-to-v3.json", "installed.bin", "v3.bin", "v2.download"])
        downloaded = (self.folder / "v2.download").read_bytes()
        first_patch = (self.folder / "v1.download").read_bytes()
        for path in ("v1.download", "v2.download"):
            (self.folder / path).unlink()
        self.assertLessEqual(len(first_patch), len(downloaded))
        result = self.select("v1-to-v3.json", "v2-to-v3.json")
        self.assertEqual(json.loads(result.stdout), self.expected("v2-to-v3.json", downloaded, target))
        print(result.stdout.decode("utf-8").strip())
        self.write("v2-to-v3.patch", downloaded)
        verified = self.run_cli(["verify", "--stream", "--manifest", "v2-to-v3.json",
                                 "installed.bin", "v2-to-v3.patch"])
        self.assertEqual(verified.stdout.strip(), VERIFY_SUCCESS)

    def test_smallest_patch_and_first_tie(self):
        old, new, small = ((REPLACE / f"{name}.bin").read_bytes() for name in ("old", "new", "patch"))
        extra_only = envelope([bz2.compress(integer(0) + integer(len(new)) + integer(0)),
                               bz2.compress(b""), bz2.compress(new)], len(new))
        self.assertEqual((len(small), len(extra_only)), (134, 152))
        self.write("installed.bin", old)
        self.candidate("large.json", old, new, extra_only)
        self.candidate("small.json", old, new, small)
        tied = "同尺寸.json" if os.name == "nt" else '同"尺寸.json'
        tied_arg = f".\\{tied}" if os.name == "nt" else tied
        self.candidate(tied, old, new, small)
        for paths, expected in [
            (("large.json", "small.json", tied_arg), "small.json"),
            (("large.json", tied_arg, "small.json"), tied_arg),
        ]:
            self.assertEqual(json.loads(self.select(*paths, options=("--",)).stdout),
                             self.expected(expected, small, new))

    def test_rejects_no_match_split_target_and_late_bad_manifest(self):
        old, new, patch = ((REPLACE / f"{name}.bin").read_bytes() for name in ("old", "new", "patch"))
        self.write("installed.bin", old)
        self.candidate("wrong-old.json", old[::-1], new, patch)
        self.candidate("match.json", old, new, patch)
        self.candidate("other-target.json", old, new[::-1], patch)
        self.write("broken.json", b'{"schema_version":')
        self.write("over-limit.json", b" " * 16385)
        for paths, message in [
            (("wrong-old.json",), b"no manifest matches size and SHA-256"),
            (("match.json", "other-target.json"), b"target mismatch with 'match.json' (new.sha256)"),
            (("match.json", "broken.json"), b"'broken.json': manifest JSON:"),
            (("match.json", "over-limit.json"), b"byte limit 16384 exceeded"),
        ]:
            with self.subTest(paths=paths):
                result = self.select(*paths, code=1)
                self.assertIn(message, result.stderr)
                if paths[-1] == "other-target.json":
                    print(result.stderr.decode("utf-8").strip())
        self.assertIn(b"patch/max_patch_bytes", self.select(
            "match.json", options=("--max-patch-bytes", "133"), code=1).stderr)
        self.assertIn(b"max_old_bytes", self.select(
            "match.json", options=("--max-old-bytes", "19"), code=1).stderr)
        self.assertIn(b"at least one MANIFEST_FILE", self.select(code=2).stderr)
        self.assertIn(b"not applicable to manifest select", self.select(
            "match.json", options=("--max-controls", "10"), code=2).stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    EXE = parser.parse_args().exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ManifestSelect))
    if not result.wasSuccessful() or result.testsRun != 3 or result.skipped:
        raise SystemExit(1)
