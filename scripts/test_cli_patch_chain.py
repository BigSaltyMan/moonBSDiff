"""Exercise the local chain with real patches and controlled native checkpoints."""

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import unittest

from build_cli import ROOT
from test_cli_manifest_create import identity
from test_cli_manifest_plan import prepare_two_hop
from test_cli_progress import snapshot


EXE = PROBE = None
FIRST = ("v1-to-v2.patch", "v1-to-v2.json")
SECOND = ("v2-to-v3.patch", "v2-to-v3.json")


def probe_handoffs(source):
    state = "static StreamFile stream_copy=STREAM_INVALID;"
    transfer = "stream_sizes[1]=0;\n  stream_copy=STREAM_INVALID;"
    delivery = "int ok=mbsd_deliver(path,NULL);"
    if any(source.count(marker) != 1 for marker in (state, transfer, delivery)):
        raise AssertionError("private chain instrumentation markers changed")
    return source.replace(state, state + "\nstatic int probe_handoffs;").replace(
        transfer, transfer + "\n  probe_handoffs++;"
    ).replace(delivery, delivery + '\n  if(fault==39 && stream_committed) fail("injected post-commit error",EIO);') + """
MOONBIT_FFI_EXPORT int32_t mbsd_probe_chain_clean(void) {
  return probe_handoffs==1 && stream_inputs[0]==STREAM_INVALID &&
    stream_inputs[1]==STREAM_INVALID && stream_copy==STREAM_INVALID;
}
"""


class PatchChain(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="moonbsdiff-chain-")
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.scratch = self.folder / "scratch"
        self.scratch.mkdir()
        self.env = {**os.environ, "TMP": str(self.scratch), "TEMP": str(self.scratch)}
        self.start, self.middle, self.target = prepare_two_hop(self.write, self.invoke)

    def invoke(self, *args, code=0, exe=None, progress=False):
        result = subprocess.run([exe or EXE, *args], cwd=self.folder, env=self.env,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr.decode(errors="replace"))
        self.assertEqual(result.stdout, b"")
        if code == 0 and not progress:
            self.assertEqual(result.stderr, b"")
        else:
            self.assertTrue(result.stderr)
        return result.stderr

    def write(self, name, data):
        (self.folder / name).write_bytes(data)

    def read(self, name):
        return (self.folder / name).read_bytes()

    def args(self, *pairs, output="restored.bin", options=()):
        return ["patch-chain", "--target-manifest", SECOND[1], *options,
                "installed.bin", output, *pairs]

    def files(self):
        self.assertEqual(list(self.scratch.iterdir()), [])
        return {p.name: p.read_bytes() for p in self.folder.iterdir() if p != self.scratch}

    def synchronize(self, mode, change=None):
        args = [PROBE, mode, *self.args(*FIRST, *SECOND, options=("--progress", "json"))]
        with subprocess.Popen(args, cwd=self.folder, env=self.env, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            ready = queue.Queue()
            threading.Thread(target=lambda: ready.put(child.stdout.readline()), daemon=True).start()
            try:
                self.assertEqual(ready.get(timeout=20).strip(), f"INTERRUPT_READY {child.pid}".encode())
                if mode == "cancel" and os.name == "nt":
                    self.assertEqual(len(list(self.scratch.glob(".moonbsdiff-input-*.tmp"))), 1)
                if change:
                    change()
                stdout, stderr = child.communicate(input=b"!", timeout=30)
                self.assertEqual(stdout, b"")
                return child.returncode, stderr
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=10)

    def chain_events(self, raw):
        rows = [json.loads(line) for line in raw.decode("utf-8").splitlines()]
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(set(row), {"schema_version", "event", "stage", "restored_bytes",
                                        "total_bytes", "output_committed", "message", "step", "step_count"})
            self.assertEqual(row["schema_version"], 1)
            self.assertIs(type(row["step_count"]), int)
            self.assertEqual(row["step_count"], 2)
            self.assertTrue(row["step"] is None or type(row["step"]) is int and row["step"] in (1, 2))
            self.assertIs(type(row["output_committed"]), bool)
            self.assertRegex(row["restored_bytes"], r"^[0-9]+$")
            if row["total_bytes"] is not None:
                self.assertRegex(row["total_bytes"], r"^[0-9]+$")
        return rows

    def terminal(self, rows, event, committed):
        self.assertEqual([row for row in rows if row["event"] in ("complete", "error", "cancelled")],
                         [rows[-1]])
        self.assertEqual((rows[-1]["event"], rows[-1]["step"], rows[-1]["output_committed"]),
                         (event, 2, committed))
        self.assertTrue(all(not row["output_committed"] for row in rows[:-1]))
        verified = [row for row in rows if row["event"] == "step_verified"]
        self.assertEqual([(row["stage"], row["step"], row["restored_bytes"], row["total_bytes"])
                          for row in verified], [("validating", 1, "2048", "2048")])

    def test_two_real_steps_publish_only_final_bytes(self):
        expected = self.files()
        raw = self.invoke(*self.args(*FIRST, *SECOND, options=("--progress", "json", "--")), progress=True)
        rows = self.chain_events(raw)
        self.terminal(rows, "complete", True)
        self.assertEqual([(row["event"], row["stage"], row["step"]) for row in rows], [
            ("start", "opening", None), ("phase", "preparing", 1), ("phase", "restoring", 1),
            ("progress", "restoring", 1), ("phase", "validating", 1), ("step_verified", "validating", 1),
            ("phase", "preparing", 2), ("phase", "restoring", 2), ("progress", "restoring", 2),
            ("phase", "validating", 2), ("phase", "delivering", 2), ("complete", "complete", 2),
        ])
        for index in (0, 1, 6):
            self.assertEqual((rows[index]["restored_bytes"], rows[index]["total_bytes"]), ("0", None))
        self.assertEqual((rows[-1]["restored_bytes"], rows[-1]["total_bytes"]), ("2048", "2048"))
        self.assertEqual(len(self.target), 2048)
        self.assertEqual(self.files(), {**expected, "restored.bin": self.target})
        print(f"Restored only the final 2048 bytes, SHA-256 {identity(self.target)['sha256']}")
        for index in (5, 6, 10, 11):
            print(raw.decode("utf-8").splitlines()[index])

    def test_text_progress_and_silent_default(self):
        expected = self.files()
        self.invoke(*self.args(*FIRST, *SECOND, output="quiet.bin"))
        raw = self.invoke(*self.args(*FIRST, *SECOND, options=("--progress", "text")), progress=True)
        self.assertIn(b"step_verified stage=validating step=1/2", raw)
        self.assertIn(b"phase stage=preparing step=2/2 restored_bytes=0 total_bytes=null", raw)
        self.assertIn(b"complete stage=complete step=2/2", raw)
        self.assertEqual(self.files(), {**expected, "quiet.bin": self.target, "restored.bin": self.target})
        self.assertIn(b"--progress requires text or json", self.invoke(
            *self.args(*FIRST, *SECOND, options=("--progress", "xml")), code=2))

    def test_preflight_rejects_link_mismatch_and_short_chain(self):
        wrong = json.loads(self.read(SECOND[1]))
        self.assertEqual(wrong["old"]["size_bytes"], str(len(self.middle)))
        wrong["old"]["sha256"] = identity(self.start)["sha256"]
        self.write("wrong-link.json", json.dumps(wrong).encode("utf-8"))
        expected = self.files()
        for args, step, detail in [
            (self.args(*FIRST, SECOND[0], "wrong-link.json"), 2, b"previous new vs old"),
            (self.args(*SECOND, *FIRST), 2, b"previous new vs old"),
            (self.args(*FIRST), 1, b"final new vs target"),
        ]:
            error = self.invoke(*args, code=1)
            self.assertIn(f"patch-chain step {step}:".encode(), error)
            self.assertIn(detail, error)
            self.assertIn(b"sha256 mismatch", error)
            self.assertEqual(self.files(), expected)
        self.assertIn(b"complete PATCH MANIFEST pairs", self.invoke(*self.args(FIRST[0]), code=2))
        self.assertIn(b"output precheck", self.invoke(*self.args(*FIRST, *SECOND, output=SECOND[0]), code=1))
        self.assertEqual(self.files(), expected)

    def test_second_step_failure_cancel_and_competing_output(self):
        intact = self.read(SECOND[0])
        self.write(SECOND[0], intact[:-1] + bytes([intact[-1] ^ 1]))
        expected = self.files()
        options = ("--progress", "json")
        error = self.invoke("clean", *self.args(*FIRST, *SECOND, options=options), code=1, exe=PROBE)
        rows = self.chain_events(error)
        self.terminal(rows, "error", False)
        self.assertIn("patch-chain step 2: patch input sha256 mismatch", rows[-1]["message"])
        self.assertEqual(rows[-1]["stage"], "preparing")
        self.assertEqual(self.files(), expected)
        print(error.decode().splitlines()[-1])
        self.write(SECOND[0], intact)
        expected = self.files()
        code, error = self.synchronize("cancel")
        self.assertEqual(code, 130, error)
        rows = self.chain_events(error)
        self.terminal(rows, "cancelled", False)
        self.assertEqual((rows[-1]["stage"], rows[-1]["restored_bytes"], rows[-1]["total_bytes"]),
                         ("preparing", "0", None))
        self.assertIn("patch-chain step 2: Cancellation confirmed", rows[-1]["message"])
        self.assertEqual(self.files(), expected)
        code, error = self.synchronize("race", lambda: self.write("restored.bin", b"competing target"))
        self.assertEqual(code, 1, error)
        rows = self.chain_events(error)
        self.terminal(rows, "error", False)
        self.assertIn("deliver without replacement", rows[-1]["message"])
        self.assertEqual(self.files(), {**expected, "restored.bin": b"competing target"})
        error = self.invoke("post-commit", *self.args(*FIRST, *SECOND, output="published.bin", options=options),
                            code=1, exe=PROBE)
        rows = self.chain_events(error)
        self.terminal(rows, "error", True)
        self.assertIn("injected post-commit error", rows[-1]["message"])
        self.assertEqual(self.files(), {**expected, "restored.bin": b"competing target", "published.bin": self.target})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    EXE = parser.parse_args().exe.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="chain-probe-", dir=ROOT / "_build") as folder:
        PROBE = snapshot(Path(folder), template="patch_chain_probe.mbt.in", native_transform=probe_handoffs)
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(PatchChain))
    if not result.wasSuccessful() or result.testsRun != 4 or result.skipped:
        raise SystemExit(1)
