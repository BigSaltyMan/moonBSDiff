"""Compare the native CLI with the public bundle API for one level-1 fixture."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from build_cli import ROOT, version


def content(data):
    return {"size_bytes": str(len(data)), "sha256": hashlib.sha256(data).hexdigest()}


def check(exe):
    command = [
        "moon", "test", "manifest/bundle_test.mbt", "--filter",
        "manifest bundle matches root options", "--target", "native", "--deny-warn",
    ]
    output = subprocess.check_output(command, cwd=ROOT, timeout=120, text=True)
    lines = output.splitlines()
    rows = [line.removeprefix("BUNDLE:") for line in lines if line.startswith("BUNDLE:")]
    if len(rows) != 1 or "Total tests: 1, passed: 1, failed: 0." not in lines:
        raise AssertionError(f"missing or duplicate bundle fixture in test output: {output}")
    patch, manifest = map(bytes.fromhex, rows[0].split(":"))
    old, new = b"abc\x00\xff", b"abC\x00\xff!"
    with tempfile.TemporaryDirectory(prefix="moonbsdiff-bundle-") as folder:
        old_path, new_path, patch_path, manifest_path = (
            Path(folder) / name for name in ("old", "new", "patch", "manifest.json")
        )
        old_path.write_bytes(old)
        new_path.write_bytes(new)
        subprocess.run([
            exe, "diff", "--manifest", manifest_path, "--compression-level", "1",
            old_path, new_path, patch_path,
        ], check=True, timeout=30)
        if (patch_path.read_bytes(), manifest_path.read_bytes()) != (patch, manifest):
            raise AssertionError("CLI and library outputs differ")

    expected = {
        "schema_version": 1,
        "patch_format": "BSDIFF40",
        "producer": {"name": "moonbsdiff", "version": version()},
        "old": content(old),
        "new": content(new),
        "patch": content(patch),
    }
    expected_manifest = (json.dumps(expected, separators=(",", ":")) + "\n").encode("utf-8")
    if manifest != expected_manifest:
        raise AssertionError("manifest differs from independently serialized schema and hashes")
    print(f"Bundle parity: patch {len(patch)} bytes, manifest {len(manifest)} bytes, "
          f"patch SHA-256 {expected['patch']['sha256']}; independent identities match")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    check(parser.parse_args().exe.resolve(strict=True))
