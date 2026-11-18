"""Four focused checks for inspect --deep using independent BSDIFF40 envelopes."""
import argparse
import bz2
import json
from pathlib import Path
import unittest

import test_cli as shared
from test_cli_inspect import InspectCli, expected, header
from test_cli_stream import envelope, integer

TRIPLES = [(2, 1, -5), (0, 0, 4), (1, 2, 0)]
STATS = dict(control_count="3", diff_bytes="3", extra_bytes="3", expanded_bytes="78")


def streams(triples=TRIPLES, delta=b"abc", extra=b"XYZ"):
    control = b"".join(integer(value) for triple in triples for value in triple)
    return [bz2.compress(block) for block in (control, delta, extra)]


class DeepInspect(unittest.TestCase):
    setUp = shared.CliFiles.setUp
    invoke = InspectCli.invoke

    def deep(self, *options, code=0):
        return self.invoke(["inspect", "--deep", *options, self.patch], code)

    def test_statistics_and_checks(self):
        packed = streams()
        sample = envelope(packed, 6)
        self.patch.write_bytes(sample)
        document = json.loads(self.deep("--json").stdout)
        want = expected(self.patch, len(sample), len(packed[0]), len(packed[1]), 6)
        want.update(STATS, validation="deep")
        want["checks"].update(compressed_streams="passed", crc="passed",
                              control_instructions="passed", complete_consumption="passed")
        self.assertEqual(document, want)
        self.assertEqual(int(document["diff_bytes"]) + int(document["extra_bytes"]),
                         int(document["new_bytes"]))
        self.assertEqual(int(document["expanded_bytes"]),
                         24*int(document["control_count"]) + int(document["new_bytes"]))
        text = self.deep().stdout.decode("utf8").splitlines()
        self.assertEqual(text[6:], [
            "Validation: deep", "Control count: 3", "Diff bytes: 3", "Extra bytes: 3",
            "Expanded bytes: 78", "Compressed streams / CRC: passed",
            "Control instructions: passed", "Complete consumption: passed",
            "Restoration: not checked", "Identity: not checked",
        ])

    def test_header_passes_and_deep_checks_crc(self):
        packed = streams()
        damaged = bytearray(packed[1])
        damaged[10] ^= 1  # First bzip2 block CRC byte, after magic and marker.
        packed[1] = bytes(damaged)
        raw = envelope(packed, 6)
        self.patch.write_bytes(raw)
        result = self.invoke(["inspect", "--json", self.patch])
        self.assertEqual(json.loads(result.stdout),
                         expected(self.patch, len(raw), len(packed[0]), len(packed[1]), 6))
        error = self.deep("--json", code=1).stderr
        self.assertIn(b"kind: DecompressionFailed", error)
        self.assertIn(b"stage: Diff", error)
        self.assertIn(b'field: Some("crc")', error)
        empty = bz2.compress(b"")
        damaged_empty = empty[:-1] + bytes([empty[-1] ^ 1])
        self.patch.write_bytes(envelope([empty, empty, damaged_empty], 0))
        error = self.deep("--json", code=1).stderr
        self.assertIn(b"kind: DecompressionFailed", error)
        self.assertIn(b"stage: Extra", error)
        self.assertIn(b'field: Some("crc")', error)
        self.patch.write_bytes(envelope([empty]*3, 0))
        self.assertEqual(json.loads(self.deep("--json").stdout)["expanded_bytes"], "0")

    def test_control_and_data_mismatch(self):
        tailed = streams()
        tailed[2] += b"garbage"
        rows = [
            (streams(delta=b"ab"), b"TruncatedData", b"Diff", b"decoded_consumption"),
            (streams(extra=b"XYZ!"), b"InvalidField", b"Extra", b"unconsumed_decoded_data"),
            (tailed, b"InvalidField", b"Extra", b"trailing data after single bzip2 stream"),
            (streams([(-1, 0, 0)]), b"InvalidField", b"Control", b"x"),
            (streams([(2, 5, 0)]), b"OutputOutOfBounds", b"Control", b"y"),
            (streams([(0, 0, (1 << 63)-1), (1, 0, 0)]), b"IntegerOverflow", b"Control", b"old_plus_x"),
        ]
        for packed, kind, stage, field in rows:
            with self.subTest(kind=kind, stage=stage, field=field):
                self.patch.write_bytes(envelope(packed, 6))
                error = self.deep("--json", code=1).stderr
                self.assertIn(b"kind: " + kind, error)
                self.assertIn(b"stage: " + stage, error)
                self.assertIn(b'field: Some("' + field + b'")', error)

    def test_resource_boundaries(self):
        self.patch.write_bytes(envelope(streams(), 6))
        result = self.deep("--max-expanded-bytes", "78B", "--max-controls", "3",
                           "--max-output-bytes", "6", "--json")
        self.assertEqual({k: json.loads(result.stdout)[k] for k in STATS}, STATS)
        for option, value, diagnostic in [
            ("--max-expanded-bytes", "77", b"decompressed_remaining"),
            ("--max-controls", "2", b"max_control_instructions"),
            ("--max-output-bytes", "5", b"max_output_bytes"),
        ]:
            with self.subTest(option=option):
                self.assertIn(diagnostic, self.deep(option, value, "--json", code=1).stderr)
                self.invoke(["inspect", option, value, self.patch], 2)
        self.patch.write_bytes(header(new=(1 << 63)-1))
        error = self.deep("--json", code=1).stderr
        self.assertIn(b"max_output_bytes", error)
        self.assertIn(b"9223372036854775807", error)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    args = parser.parse_args()
    shared.EXE = args.exe.resolve(strict=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(DeepInspect))
    if not result.wasSuccessful() or result.testsRun != 4 or result.skipped:
        raise SystemExit(1)
