"""Four focused checks for schema-1 manifest stream recovery."""
import argparse
import bz2
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import unittest

from build_cli import ROOT
from test_cli_progress import events, snapshot

EXE = PROBE = None


class StreamManifest(unittest.TestCase):
    def setUp(self):
        work = tempfile.TemporaryDirectory(prefix="moonbsdiff-stream-manifest-")
        self.addCleanup(work.cleanup)
        self.folder = Path(work.name)
        self.old, self.new, self.patch, self.manifest, self.output = [
            self.folder / name for name in ["old", "new", "patch", "manifest.json", "output"]
        ]
        self.scratch = self.folder / "scratch"
        self.scratch.mkdir()
        self.env = {**os.environ, "TMP": str(self.scratch), "TEMP": str(self.scratch)}
        self.original = bytes(range(256))*36
        self.target = self.original[:7000] + b"changed" + self.original[7011:] + b"tail"
        self.old.write_bytes(self.original)
        self.new.write_bytes(self.target)
        result = subprocess.run(
            [EXE, "diff", "--manifest", self.manifest, self.old, self.new, self.patch],
            capture_output=True, timeout=30, env=self.env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.original_patch = self.patch.read_bytes()
        self.original_manifest = self.manifest.read_bytes()

    def args(self, *limits):
        return ["patch", "--stream", "--manifest", self.manifest, "--progress", "json",
                *limits, self.old, self.patch, self.output]

    def invoke(self, code, *limits):
        result = subprocess.run([EXE, *self.args(*limits)], capture_output=True,
                                timeout=30, env=self.env)
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assert_clean()
        return events(result.stderr)

    def assert_clean(self):
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertEqual(list(self.folder.glob(".moonbsdiff-*")), [])

    def synchronize(self, point, mutate, *limits):
        with subprocess.Popen(
            [PROBE, point, "none", *self.args(*limits)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env,
        ) as child:
            ready = queue.Queue()
            threading.Thread(target=lambda: ready.put(child.stdout.readline()), daemon=True).start()
            try:
                self.assertEqual(ready.get(timeout=25).strip(),
                                 f"INTERRUPT_READY {child.pid}".encode())
                if os.name != "nt":
                    links = []
                    for entry in Path(f"/proc/{child.pid}/fd").iterdir():
                        links.append(os.readlink(entry))
                    expected_copies = 2 if point == "copied" else 1
                    self.assertEqual(sum("moonbsdiff-compat-" in x and x.endswith(" (deleted)")
                                         for x in links), expected_copies)
                else:
                    self.assertEqual(len(list(self.scratch.glob(".moonbsdiff-input-*.tmp"))),
                                     2 if point == "copied" else 1)
                mutate()
                stdout, stderr = child.communicate(input=b"!", timeout=30)
                self.assertEqual(child.returncode, 0, stderr)
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=10)
        self.assert_clean()
        return json.loads(stdout), events(stderr)

    def test_normal_recovery(self):
        rows = self.invoke(0)
        preparation = [x for x in rows if x["stage"] == "preparing"]
        self.assertTrue(preparation)
        self.assertTrue(all(x["restored_bytes"] == "0" for x in preparation))
        self.assertEqual(rows[-1]["event"], "complete")
        self.assertTrue(rows[-1]["output_committed"])
        self.assertEqual(rows[-1]["restored_bytes"], str(len(self.target)))
        self.assertEqual(self.output.read_bytes(), self.target)

    def test_identity_errors(self):
        for path, raw, name in [(self.old, self.original, "old input"),
                                 (self.patch, self.original_patch, "patch input")]:
            path.write_bytes(bytes([raw[0] ^ 1]) + raw[1:])
            rows = self.invoke(1)
            self.assertIn(name + " sha256 mismatch", rows[-1]["message"])
            self.assertFalse(self.output.exists())
            self.assertEqual(rows[-1]["restored_bytes"], "0")
            path.write_bytes(raw)
        doc = json.loads(self.original_manifest)
        doc["new"]["sha256"] = "0"*64
        self.manifest.write_text(json.dumps(doc), encoding="utf8")
        rows = self.invoke(1)
        self.assertEqual(rows[-1]["stage"], "validating")
        self.assertEqual(rows[-1]["restored_bytes"], str(len(self.target)))
        self.assertIn("restored new content sha256 mismatch", rows[-1]["message"])
        self.assertFalse(rows[-1]["output_committed"])
        self.assertFalse(self.output.exists())

    def test_verified_copy_used_after_paths_change(self):
        control_size = int.from_bytes(self.original_patch[8:16], "little")
        control = bz2.decompress(self.original_patch[32:32+control_size])
        self.assertTrue(any(int.from_bytes(control[i:i+8], "little") > 0
                            for i in range(0, len(control), 24)))

        def mutate():
            self.old.write_bytes(b"X"*len(self.original))
            replacement = self.folder / "replacement"
            replacement.write_bytes(b"Y"*len(self.original_patch))
            replacement.replace(self.patch)
        summary, rows = self.synchronize("copied", mutate)
        self.assertEqual(summary, dict(first_code=0, first_published=True,
                                       retry_code=1, retry_published=False))
        self.assertEqual(self.output.read_bytes(), self.target)
        self.assertIn("old input sha256 mismatch", rows[-1]["message"])

    def test_copy_limit_and_cancel(self):
        rows = self.invoke(1, "--max-old-bytes", str(len(self.original)-1))
        self.assertIn("old/max_old_bytes", rows[-1]["message"])
        self.old.write_bytes(self.original + b"X")
        rows = self.invoke(1, "--max-old-bytes", str(len(self.original)))
        self.assertIn("max_old_bytes", rows[-1]["message"])
        self.assertFalse(self.output.exists())
        self.old.write_bytes(self.original)
        if os.name != "nt":
            def grow():
                with self.old.open("ab") as source:
                    source.write(b"X")
            summary, rows = self.synchronize(
                "copy-grow", grow, "--max-old-bytes", str(len(self.original)))
            self.assertEqual(summary, dict(first_code=1, first_published=False,
                                           retry_code=1, retry_published=False))
            self.assertIn("input grew beyond verified length",
                          next(x for x in rows if x["event"] == "error")["message"])
            self.assertFalse(self.output.exists())
            self.old.write_bytes(self.original)
        summary, rows = self.synchronize("copy-cancel", lambda: self.output.write_bytes(b"competitor"))
        self.assertEqual(summary, dict(first_code=130, first_published=False,
                                       retry_code=0, retry_published=True))
        cancelled = next(x for x in rows if x["event"] == "cancelled")
        self.assertEqual(cancelled["stage"], "preparing")
        self.assertEqual(cancelled["restored_bytes"], "0")
        self.assertFalse(cancelled["output_committed"])
        self.assertEqual(self.output.read_bytes(), b"competitor")
        self.assertEqual(self.output.with_suffix(".retry").read_bytes(), self.target)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="c28-probe-", dir=ROOT/"_build") as folder:
        PROBE = snapshot(Path(folder))
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(StreamManifest))
    if not result.wasSuccessful() or result.testsRun != 4 or result.skipped:
        raise SystemExit(1)
