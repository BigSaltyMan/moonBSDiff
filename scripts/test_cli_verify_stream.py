"""Four focused checks for verify --stream."""
import argparse
import bz2
from hashlib import sha256
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from build_cli import ROOT
from test_cli_progress import snapshot
from test_cli_stream import envelope
import test_cli_stream_manifest as manifest_fixture

EXE = PROBE = None
SUCCESS = b"Verification succeeded: manifest, inputs and restored content match (not publisher authentication)."


def guard_output_paths(source):
    # The private executable must abort even if an accidental output would be
    # removed before the process exits. The production native source stays intact.
    for signature in [
        "mbsd_deliver(moonbit_bytes_t name,moonbit_bytes_t data) {",
        "mbsd_stream_write(moonbit_bytes_t data) {",
        "mbsd_stream_deliver(moonbit_bytes_t path,int32_t (*call)(void*),void *context,void *gate) {",
        "mbsd_interrupt_commit(int32_t token) {",
    ]:
        if source.count(signature) != 1:
            raise ValueError("missing output-path guard: "+signature)
        source = source.replace(signature, signature + '\n  abort();', 1)
    cleanup = "void mbsd_stream_abort(void) { stream_close_inputs(); }"
    if source.count(cleanup) != 1:
        raise ValueError("missing cleanup injection point")
    return source.replace(cleanup, """void mbsd_stream_abort(void) {
  stream_close_inputs();
  if(stream_inputs[0]!=STREAM_INVALID || stream_inputs[1]!=STREAM_INVALID ||
     stream_copy!=STREAM_INVALID) abort();
  if(fault==29) fail("injected verification input close failure",EIO);
}""", 1)


class VerifyStream(unittest.TestCase):
    setUp = manifest_fixture.StreamManifest.setUp
    assert_clean = manifest_fixture.StreamManifest.assert_clean

    def args(self, *options):
        return ["verify", "--stream", "--manifest", self.manifest, *options,
                self.old, self.patch]

    def run_verify(self, args, code, exe=None):
        result = subprocess.run([exe or EXE, *args], cwd=self.folder, env=self.env,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [SUCCESS] if code == 0 else [])
        self.assert_clean()
        self.assertFalse(self.output.exists())
        return result.stderr

    def test_normal_no_output_calls(self):
        self.assertGreater(len(self.target), 8192)
        self.assertEqual(self.run_verify(self.args(), 0, PROBE), b"")

    def test_target_hash_and_empty_stream_crc(self):
        doc = json.loads(self.original_manifest)
        doc["new"]["sha256"] = "0"*64
        self.manifest.write_text(json.dumps(doc), encoding="utf8")
        error = self.run_verify(self.args(), 1)
        self.assertIn(b"restored new content sha256 mismatch", error)
        empty = bz2.compress(b"")
        bad_crc = bytearray(empty)
        bad_crc[-1] ^= 1  # Empty stream has a byte-aligned end marker and combined CRC.
        for stream_index in range(3):
            with self.subTest(stream=stream_index):
                streams = [empty]*3
                streams[stream_index] = bytes(bad_crc)
                raw = envelope(streams, 0)
                self.patch.write_bytes(raw)
                doc["patch"] = dict(size_bytes=str(len(raw)), sha256=sha256(raw).hexdigest())
                doc["new"] = dict(size_bytes="0", sha256=sha256(b"").hexdigest())
                self.manifest.write_text(json.dumps(doc), encoding="utf8")
                error = self.run_verify(self.args(), 1)
                self.assertIn(b"Checksum", error)
        raw = envelope([empty]*3, 0)
        self.patch.write_bytes(raw)
        doc["patch"] = dict(size_bytes=str(len(raw)), sha256=sha256(raw).hexdigest())
        self.manifest.write_text(json.dumps(doc), encoding="utf8")
        self.assertEqual(self.run_verify(self.args(), 0), b"")

    def test_arguments_and_limits(self):
        error = self.run_verify(["verify", "--stream", self.old, self.patch], 2)
        self.assertIn(b"requires --manifest", error)
        self.run_verify([*self.args(), self.output], 2)
        self.run_verify(self.args("--progress", "json"), 2)
        error = self.run_verify(self.args("--max-output-bytes", str(len(self.target)-1)), 1)
        self.assertIn(b"new/max_output_bytes", error)

    def test_cancel_and_cleanup(self):
        error = self.run_verify(["cancel", *self.args()], 130, PROBE)
        self.assertIn(b"Cancellation confirmed", error)
        error = self.run_verify(["close-error", *self.args()], 1, PROBE)
        self.assertIn(b"injected verification input close failure", error)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    args = parser.parse_args()
    EXE = args.exe.resolve(strict=True)
    manifest_fixture.EXE = EXE
    with tempfile.TemporaryDirectory(prefix="c29-probe-", dir=ROOT/"_build") as folder:
        PROBE = snapshot(Path(folder), template="verify_stream_probe.mbt.in",
                         native_transform=guard_output_paths)
        result = unittest.TextTestRunner(verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(VerifyStream))
    if not result.wasSuccessful() or result.testsRun != 4 or result.skipped:
        raise SystemExit(1)
