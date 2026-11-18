"""Verify manifest creation for an existing upstream BSDIFF40 patch."""

import argparse
import hashlib
import json
from pathlib import Path
import unittest

from build_cli import ROOT, version
import test_cli as shared


UPSTREAM = ROOT / "testdata/upstream"
VERIFY_SUCCESS = (
    b"Verification succeeded: manifest, inputs and restored content match "
    b"(not publisher authentication)."
)


def identity(data):
    return {"size_bytes": str(len(data)), "sha256": hashlib.sha256(data).hexdigest()}


class ManifestCreate(unittest.TestCase):
    run_cli = shared.CliFiles.run_cli

    def setUp(self):
        shared.CliFiles.setUp(self)
        self.inputs = {"old": self.old, "new": self.new, "patch": self.patch}
        self.original = self.load_case("replace")
        self.manifest = self.p / "update.json"

    def load_case(self, name):
        source = UPSTREAM / name
        data = {key: (source / f"{key}.bin").read_bytes() for key in self.inputs}
        for key, path in self.inputs.items():
            path.write_bytes(data[key])
        return data

    def create(self, *options, new=None, output=None, code=0):
        result = self.run_cli([
            "manifest", "create", *options, self.old, new or self.new,
            self.patch, output or self.manifest,
        ], code)
        self.assertEqual(result.stdout, b"")
        return result

    def test_upstream_manifest_and_stream_verification(self):
        self.create()
        document = json.loads(self.manifest.read_bytes())
        self.assertEqual(document, {
            "schema_version": 1,
            "patch_format": "BSDIFF40",
            "producer": {"name": "moonbsdiff", "version": version()},
            **{name: identity(raw) for name, raw in self.original.items()},
        })
        for name, path in self.inputs.items():
            self.assertEqual(path.read_bytes(), self.original[name])
        result = self.run_cli([
            "verify", "--stream", "--manifest", self.manifest, self.old, self.patch,
        ])
        self.assertEqual(result.stdout.rstrip(b"\r\n"), VERIFY_SUCCESS)
        print(f"Upstream replace: patch SHA-256 {identity(self.original['patch'])['sha256']}; "
              f"manifest SHA-256 field {document['patch']['sha256']}; verify --stream exit 0")

        identical = self.load_case("identical")
        self.assertEqual(identical["old"], identical["new"])
        output = self.p / "-identical.json"
        result = self.run_cli([
            "manifest", "create", "--", self.old, self.old, self.patch, output.name,
        ])
        self.assertEqual(result.stdout, b"")
        document = json.loads(output.read_bytes())
        self.assertEqual(document["new"], identity(identical["new"]))

    def test_equal_length_wrong_target(self):
        expected = self.original["new"]
        self.new.write_bytes(bytes([expected[0] ^ 1]) + expected[1:])
        self.assertEqual(self.new.stat().st_size, len(expected))
        result = self.create(code=1)
        self.assertIn(b"restored content differs from expected new file", result.stderr)
        self.assertFalse(self.manifest.exists())

    def test_corrupt_patch_and_application_limits(self):
        patch = bytearray(self.original["patch"])
        # The fixed fixture has a nonempty control stream. Flip its block CRC.
        self.assertEqual(patch[32:42], b"BZh91AY&SY")
        patch[42] ^= 1
        self.patch.write_bytes(patch)
        result = self.create(code=1)
        self.assertIn(b"manifest create apply", result.stderr)
        self.assertIn(b"kind: DecompressionFailed", result.stderr)
        self.assertIn(b"stage: Control", result.stderr)
        self.assertIn(b'field: Some("crc")', result.stderr)
        self.assertFalse(self.manifest.exists())
        self.patch.write_bytes(self.original["patch"])
        too_small = str(len(self.original["new"]) - 1)
        for limit in ("--max-new-bytes", "--max-output-bytes"):
            with self.subTest(limit=limit):
                result = self.create(limit, too_small, code=1)
                self.assertIn(b"read expected new", result.stderr)
                self.assertIn(b"input size", result.stderr)
                self.assertFalse(self.manifest.exists())

    def test_output_and_arguments(self):
        self.manifest.write_bytes(b"keep existing manifest")
        self.assertIn(b"output already exists", self.create(code=1).stderr)
        self.assertEqual(self.manifest.read_bytes(), b"keep existing manifest")
        alias = self.p / "patch-alias.json"
        alias.hardlink_to(self.patch)
        self.create(output=alias, code=1)
        self.assertEqual(self.patch.read_bytes(), self.original["patch"])
        self.assertEqual(alias.read_bytes(), self.original["patch"])
        result = self.run_cli(["manifest", "create", self.old, self.new, self.patch], 2)
        self.assertIn(b"expected exactly 4 file arguments", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    shared.EXE = args.exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ManifestCreate)
    )
    if not result.wasSuccessful() or result.testsRun != 4 or result.skipped:
        raise SystemExit(1)
