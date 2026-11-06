"""Failure-path checks use temporary copies; fixed fixtures are never edited."""
import json
import importlib.util
from unittest.mock import patch
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import generate_reference as ref

class ReferenceFailures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = pathlib.Path(self.temp.name)
        self.data = self.work/"data"
        shutil.copytree(ref.DATA, self.data)

    def reject_manifest(self, mutate):
        path = self.data/"manifest.json"
        manifest = json.loads(path.read_text())
        mutate(manifest)
        path.write_text(json.dumps(manifest))
        with self.assertRaises((AssertionError, ValueError)):
            ref.verify(self.data)

    def test_missing_file(self):
        (self.data/"identical/old.bin").unlink()
        with self.assertRaises(FileNotFoundError):
            ref.verify(self.data)

    def test_modified_patch(self):
        path = self.data/"identical/patch.bin"
        path.write_bytes(path.read_bytes()+b"corrupt")
        with self.assertRaises(AssertionError):
            ref.verify(self.data)

    def test_wrong_hash(self):
        self.reject_manifest(lambda m: m["cases"][0]["old"].update(sha256="0"*64))

    def test_wrong_size(self):
        self.reject_manifest(lambda m: m["cases"][0]["new"].update(size=1))

    def test_missing_case(self):
        self.reject_manifest(lambda m: m["cases"].pop())

    def test_corrupt_archive_cache(self):
        spec = importlib.util.spec_from_file_location("oracle_build", ref.ROOT/"tools/oracle/build.py")
        oracle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(oracle)
        lock = json.loads(ref.LOCK.read_text())
        (self.work/lock["bsdiff"]["archive"]).write_bytes(b"not the fixed archive")
        with patch.object(oracle, "CACHE", self.work):
            with self.assertRaises(ValueError):
                oracle.archive(lock["bsdiff"])

    def test_nonzero_exit(self):
        with self.assertRaises(subprocess.CalledProcessError):
            ref.run_output([sys.executable,"-c","raise SystemExit(9)"],self.work/"out")

    def test_timeout(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            ref.run_output([sys.executable,"-c","import time; time.sleep(5)"],self.work/"out",timeout=0.1)

    def test_output_missing(self):
        with self.assertRaises(ValueError):
            ref.run_output([sys.executable,"-c","pass"],self.work/"out")

    def test_restored_corruption(self):
        output = self.work/"out"
        actual = ref.run_output([sys.executable,"-c","import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b'broken')",output],output)
        with self.assertRaises(ValueError):
            ref.compare(actual,b"original new data")

if __name__ == "__main__":
    unittest.main()
