"""Check indexed batch CLI outputs, whole-batch preflight and partial delivery."""

import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_cli import ROOT
from test_cli_progress import snapshot


EXE = PROBE = None
TARGETS = {"beta": b"ABXDE", "rc": b"prefix-ABCDE!", "later": b"ABCDE-suffix"}


def inject_delivery_errors(source):
    entry = "mbsd_deliver(moonbit_bytes_t name,moonbit_bytes_t data) {\n"
    start = source.index(entry) + len(entry)
    end = source.index("\n}\n", start)
    delivery = source[start:end]
    result = "return !problem[0];"
    if delivery.count(result) != 3:
        raise AssertionError("delivery result sites changed")
    # Test snapshot only. Use the existing fault before publishing rc.json,
    # and simulate an error after cleanup for an already published file.
    delivery = delivery.replace(result, (
        'if(delivery_committed && (!strcmp((const char*)name,"rc-post.patch") || '
        '!strcmp((const char*)name,"rc-post-manifest.json"))) '
        'fail("injected post-delivery error",EIO);\n  ' + result
    ))
    delivery = '  if(!strcmp((const char*)name,"rc.json")) fault=6;\n' + delivery
    return source[:start] + delivery + source[end:]


class DiffMany(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="moonbsdiff-many-")
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        (self.folder / "stable.bin").write_bytes(b"ABCDE")
        for name, data in TARGETS.items():
            (self.folder / f"{name}.bin").write_bytes(data)

    def invoke(self, *args, code=0, exe=None):
        result = subprocess.run([exe or EXE, *args], cwd=self.folder,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        if code == 0:
            self.assertEqual(result.stderr, b"")
        return result.stderr.decode(errors="replace").strip()

    def batch(self, *names, suffix=""):
        return ["diff-many", "--compression-level", "6", "stable.bin", *(
            path for name in names
            for path in (f"{name}.bin", f"{name}{suffix}.patch", f"{name}{suffix}.json")
        )]

    def assert_restored(self, group, suffix=""):
        target = self.folder / f"{group}{suffix}.restored"
        self.invoke("patch", "--manifest", f"{group}{suffix}.json", "stable.bin",
                    f"{group}{suffix}.patch", target)
        self.assertEqual(target.read_bytes(), TARGETS[group])

    def test_two_bundles_match_single_generation_and_restore(self):
        self.invoke(*self.batch("beta", "rc"))
        for group in ("beta", "rc"):
            self.invoke("diff", "--compression-level", "6", "--manifest", f"{group}-single.json",
                        "stable.bin", f"{group}.bin", f"{group}-single.patch")
            patch, manifest = ((self.folder / f"{group}.{ext}").read_bytes() for ext in ("patch", "json"))
            self.assertEqual(patch, (self.folder / f"{group}-single.patch").read_bytes())
            self.assertEqual(manifest, (self.folder / f"{group}-single.json").read_bytes())
            self.assert_restored(group)
            print(f"{group}: {len(patch)} patch bytes and {len(manifest)} manifest bytes match; restored {TARGETS[group]!r}")

    def test_whole_batch_preflight_and_argument_errors(self):
        (self.folder / "nested").mkdir()
        args = self.batch("beta", "rc")
        conflict = args[:-1] + ["nested/../beta.patch"]
        error = self.invoke(*conflict, code=1)
        self.assertIn("group 2 failed (completed groups: 0, group patch delivered: no)", error)
        self.assertIn("same target", error)
        print(error)

        # The first patch cannot occupy a missing input used by a later group.
        conflict = args.copy()
        conflict[-3] = "nested/../beta.patch"
        error = self.invoke(*conflict, code=1)
        self.assertIn("against input 'nested/../beta.patch'", error)
        self.assertIn("same target", error)
        self.assertIn("complete NEW PATCH MANIFEST groups", self.invoke(*args[:-1], code=2))
        self.assertIn("MANIFEST file argument per group", self.invoke(
            "diff-many", "--manifest", "unused.json", *args[3:], code=2))
        self.assertFalse(list(self.folder.glob("*.patch")))
        self.assertFalse(list(self.folder.glob("*.json")))

    def test_partial_delivery_stops_later_groups(self):
        for suffix, detail, complete in (
            ("", "manifest 'rc.json' not delivered", 1),
            ("-post", "deliver patch 'rc-post.patch'", 1),
            ("-post-manifest", "manifest 'rc-post-manifest.json' delivered with an error", 2),
        ):
            with self.subTest(suffix=suffix):
                error = self.invoke(*self.batch("beta", "rc", "later", suffix=suffix),
                                    code=1, exe=PROBE)
                self.assertIn(f"group 2 failed (completed groups: {complete}, group patch delivered: yes)", error)
                self.assertIn(detail, error)
                self.assertIn("injected", error)
                self.assert_restored("beta", suffix)
                self.assertTrue((self.folder / f"rc{suffix}.patch").is_file())
                if complete == 2:
                    self.assert_restored("rc", suffix)
                else:
                    self.assertFalse((self.folder / f"rc{suffix}.json").exists())
                for name in (f"later{suffix}.patch", f"later{suffix}.json"):
                    self.assertFalse((self.folder / name).exists(), name)
                print(error)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    EXE = parser.parse_args().exe.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="c36-probe-", dir=ROOT / "_build") as folder:
        PROBE = snapshot(Path(folder), template="diff_many_probe.mbt.in",
                         native_transform=inject_delivery_errors)
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(DiffMany))
    if not result.wasSuccessful() or result.testsRun != 3 or result.skipped:
        raise SystemExit(1)
