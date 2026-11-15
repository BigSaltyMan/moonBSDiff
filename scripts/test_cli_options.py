"""Only new compression-option parsing/display/manifest integration."""
import argparse
import hashlib
import json
import pathlib
import platform
import unittest

import test_cli as shared
from check_diff import parse


class CliOptions(unittest.TestCase):
    setUp = shared.CliFiles.setUp
    run_cli = shared.CliFiles.run_cli

    def test_effective_option_display_without_io(self):
        before = {p.name: p.read_bytes() for p in self.p.iterdir()}
        for flags, level in [([], 9), (['--compression-level', '1', '--max-old-bytes', '256KiB'], 1)]:
            r = self.run_cli(['diff', *flags, '--show-limits'])
            lines = dict(line.split(': ', 1) for line in r.stdout.decode().splitlines())
            self.assertEqual(lines['compression_level'], str(level)+' (generation option; bzip2)')
            self.assertEqual(lines['max_new_bytes'], '65536 bytes')
        self.assertNotIn(b'compression_level', self.run_cli(['patch', '--show-limits']).stdout)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.p.iterdir()})

    def test_rejected_values_and_operations(self):
        rows = [['diff', '--compression-level'],
                ['diff', '--compression-level', '1', '--compression-level', '9', '--show-limits']]
        rows += [['diff', '--compression-level', v, '--show-limits'] for v in
                 ['0', '-1', '10', '9223372036854775808', '1KiB', '1.0', 'x']]
        rows += [[op, '--compression-level', '1'] for op in ['patch', 'verify', 'inspect']]
        for args in rows:
            with self.subTest(args=args):
                self.run_cli(args, 2)

    def test_nondefault_manifest_checked_restore_and_end_options(self):
        manifest = self.p/'update.json'
        self.run_cli(['diff', '--manifest', manifest, '--max-old-bytes', '5', '--compression-level', '6',
                      '--', self.old, self.new, self.patch])
        patch = self.patch.read_bytes()
        parse(patch, self.old.read_bytes(), self.new.read_bytes(), level=6)
        doc = json.loads(manifest.read_bytes())
        self.assertEqual(set(doc), {'schema_version', 'patch_format', 'producer', 'old', 'new', 'patch'})
        self.assertEqual(doc['schema_version'], 1)
        for key, path in [('old', self.old), ('new', self.new), ('patch', self.patch)]:
            raw = path.read_bytes()
            self.assertEqual(doc[key], dict(size_bytes=str(len(raw)), sha256=hashlib.sha256(raw).hexdigest()))
        self.run_cli(['verify', '--manifest', manifest, self.old, self.patch])
        self.run_cli(['patch', '--manifest', manifest, self.old, self.patch, self.out])
        self.assertEqual(self.out.read_bytes(), self.new.read_bytes())
        default = self.p/'default.patch'
        explicit = self.p/'explicit-nine.patch'
        self.run_cli(['diff', self.old, self.new, default])
        self.run_cli(['diff', '--compression-level', '9', self.old, self.new, explicit])
        self.assertEqual(default.read_bytes(), explicit.read_bytes())
        self.assertEqual(default.read_bytes(), (shared.ROOT/'testdata/manifest/update.patch').read_bytes())


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--exe', required=True, type=pathlib.Path)
    a = p.parse_args()
    shared.EXE = a.exe.resolve()
    if not shared.EXE.is_file():
        raise SystemExit('CLI executable missing')
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CliOptions))
    print(json.dumps(dict(platform=platform.system(), tests=result.testsRun,
                          failed=len(result.errors)+len(result.failures), cli_invocations=shared.INVOCATIONS)))
    if not result.wasSuccessful() or result.testsRun != 3 or result.skipped:
        raise SystemExit(1)
