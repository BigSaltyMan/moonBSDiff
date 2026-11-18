"""Verify shortest-path choices and apply a real two-hop patch plan."""

import argparse
import bz2
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_cli import ROOT, version
from test_cli_manifest_create import identity
from test_cli_stream import envelope, integer


EXE = None
UPSTREAM = ROOT / "testdata/upstream/seeded-random"


def prepare_two_hop(write, invoke):
    start = (UPSTREAM / "old.bin").read_bytes()
    middle = (UPSTREAM / "new.bin").read_bytes()
    target = middle[:-1] + bytes([middle[-1] ^ 1])
    write("installed.bin", start)
    write("v2.bin", middle)
    write("v3.bin", target)
    write("v1-to-v2.patch", (UPSTREAM / "patch.bin").read_bytes())
    invoke("manifest", "create", "installed.bin", "v2.bin", "v1-to-v2.patch", "v1-to-v2.json")
    invoke("diff", "--manifest", "v2-to-v3.json", "v2.bin", "v3.bin", "v2-to-v3.patch")
    return start, middle, target


class ManifestPlan(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="moonbsdiff-plan-")
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def invoke(self, *args, code=0):
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

    def read(self, name):
        return (self.folder / name).read_bytes()

    def plan(self, marker, *edges, code=0, options=()):
        before = {p.name: p.read_bytes() for p in self.folder.iterdir()}
        result = self.invoke("manifest", "plan", "--target-manifest", marker,
                             *options, "installed.bin", *edges, code=code)
        self.assertEqual({p.name: p.read_bytes() for p in self.folder.iterdir()}, before)
        return result

    def edge(self, path, old, new, cost):
        # Declared-cost graph fixture. This case only exercises planning.
        record = {"schema_version": 1, "patch_format": "BSDIFF40",
                  "producer": {"name": "moonbsdiff", "version": version()},
                  "old": identity(old), "new": identity(new),
                  "patch": identity(bytes(cost))}
        self.write(path, json.dumps(record).encode("utf-8"))
        return path

    def test_cheaper_two_hops_actually_restore_target(self):
        start, middle, target = prepare_two_hop(self.write, self.invoke)
        # A valid direct patch that carries the complete target in Extra.
        control = integer(0) + integer(len(target)) + integer(0)
        self.write("v1-to-v3.patch", envelope([bz2.compress(control), bz2.compress(b""),
                                               bz2.compress(target)], len(target)))
        self.invoke("manifest", "create", "installed.bin", "v3.bin", "v1-to-v3.patch", "v1-to-v3.json")
        paths = ("v1-to-v2.json", "v2-to-v3.json")
        inputs = ((start, middle), (middle, target))
        steps, patches = [], {}
        for path, (old, new) in zip(paths + ("v1-to-v3.json",), inputs + ((start, target),)):
            patch_path = Path(path).with_suffix(".patch").name
            patch = self.read(patch_path)
            patches[patch_path] = patch
            (self.folder / patch_path).unlink()
            declared = json.loads(self.read(path))
            expected = {"old": identity(old), "new": identity(new), "patch": identity(patch)}
            self.assertEqual({key: declared[key] for key in expected}, expected)
            if path in paths:
                steps.append({"manifest_path": path, **expected})
        costs = [int(step["patch"]["size_bytes"]) for step in steps]
        direct = len(patches["v1-to-v3.patch"])
        self.assertLess(sum(costs), direct)

        result = self.plan(paths[1], *paths, "v1-to-v3.json")
        plan = json.loads(result.stdout)
        self.assertEqual(plan, {"schema_version": 1, "start": identity(start), "target": identity(target),
                                "total_patch_bytes": str(sum(costs)), "steps": steps})
        self.assertEqual(json.loads(self.plan(paths[1], *paths).stdout), plan)
        old_path = "installed.bin"
        for step, next_name, expected in zip(plan["steps"], ("restored-v2.bin", "restored-v3.bin"),
                                              (middle, target)):
            path = step["manifest_path"]
            patch_path = Path(path).with_suffix(".patch").name
            self.write(patch_path, patches[patch_path])
            self.invoke("patch", "--stream", "--manifest", path, old_path, patch_path, next_name)
            self.assertEqual(self.read(next_name), expected)
            old_path = next_name
        print(f"Direct: {direct} bytes. Selected: {costs[0]} + {costs[1]} = {sum(costs)} bytes. "
              f"Restored: {len(target)} bytes, SHA-256 {identity(target)['sha256']}")
        print(result.stdout.decode("utf-8").strip())

    def test_ties_parallel_edges_and_cycles(self):
        source, target = b"src", b"destination"
        self.write("installed.bin", source)
        slower = self.edge("slower.json", source, b"bee", 8)
        ab = self.edge("ab.json", source, b"bee", 4)
        ac = self.edge("ac.json", source, b"cee", 4)
        bd = self.edge("bd.json", b"bee", target, 6)
        cd = self.edge("cd.json", b"cee", target, 6)
        back = self.edge("back.json", b"bee", source, 0)
        loop = self.edge("loop.json", b"bee", b"bee", 0)
        direct = self.edge("direct.json", source, target, 10)
        tail = (slower, cd, bd, back, loop)
        for candidates, expected in [
            ((ab, ac, *tail, direct), [direct]),
            ((ab, ac, *tail), [ab, bd]),
            ((ac, ab, *tail), [ac, cd]),
        ]:
            with self.subTest(expected=expected):
                raw = self.plan(bd, *candidates).stdout
                self.assertEqual(self.plan(bd, *candidates).stdout, raw)
                plan = json.loads(raw)
                self.assertEqual(plan["total_patch_bytes"], "10")
                self.assertEqual([step["manifest_path"] for step in plan["steps"]], expected)

    def test_identity_and_validation_boundaries(self):
        old, target = b"one", b"target"
        self.write("installed.bin", old)
        first = self.edge("first.json", old, b"two", 50)
        wrong = self.edge("wrong.json", b"TWO", target, 50)
        marker = self.edge("target-label.json", old, target, 100)
        self.assertIn(b"no reachable path", self.plan(marker, first, wrong, code=1).stderr)
        self.assertIn(b"patch/max_patch_bytes", self.plan(marker, first, wrong, code=1,
                      options=("--max-patch-bytes", "99")).stderr)
        self.assertIn(b"requires --target-manifest", self.invoke(
            "manifest", "plan", "installed.bin", first, code=2).stderr)
        self.write("installed.bin", target)
        self.assertEqual(json.loads(self.plan(marker).stdout), {
            "schema_version": 1, "start": identity(target), "target": identity(target),
            "total_patch_bytes": "0", "steps": [],
        })
        self.write("broken.json", b"{")
        self.assertIn(b"'broken.json': manifest JSON:", self.plan(marker, first, "broken.json", code=1).stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    EXE = parser.parse_args().exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ManifestPlan))
    if not result.wasSuccessful() or result.testsRun != 3 or result.skipped:
        raise SystemExit(1)
