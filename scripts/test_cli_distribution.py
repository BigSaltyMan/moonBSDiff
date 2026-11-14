"""Small archive/provenance gate tests; synthetic records are not runtime evidence."""
import json
import pathlib
import tempfile
import unittest

from collect_cli_release import collect
from package_cli import archive_bytes, sha, unpack_check


class DistributionTests(unittest.TestCase):
    def test_archive_members_bytes_and_executable_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            for system in ('linux', 'windows'):
                files = {'moonbsdiff' if system == 'linux' else 'moonbsdiff.exe': b'synthetic binary', 'LICENSE': b'notice'}
                archive = root / system
                archive.write_bytes(archive_bytes(files, system, 1))
                target = root / (system + '-out')
                target.mkdir()
                unpack_check(archive, files, target, system)
                with self.assertRaises(RuntimeError):
                    unpack_check(archive, {**files, 'missing': b'x'}, target, system)
                with self.assertRaises(RuntimeError):
                    unpack_check(archive, {name: b'changed' for name in files}, target, system)

    def test_collection_rejects_missing_corrupt_and_wrong_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            source = 'a' * 40
            for system in ('linux', 'windows'):
                exe_name = 'moonbsdiff' if system == 'linux' else 'moonbsdiff.exe'
                exe = b'synthetic binary, never executed'
                info = dict(schema_version=1, version='0.2.0', platform=system, architecture='x86_64',
                            source_sha=source, build_mode='native release',
                            executable=dict(size_bytes=len(exe), sha256=sha(exe)))
                name = 'moonbsdiff-0.2.0-' + system + '-x86_64' + ('.zip' if system == 'windows' else '.tar.gz')
                raw = archive_bytes({exe_name: exe, 'build-source.json': json.dumps(info).encode()}, system, 1)
                (root / name).write_bytes(raw)
                info['archive'] = dict(name=name, size_bytes=len(raw), sha256=sha(raw))
                info['validation'] = dict(help=True, exact_version='0.2.0', byte_equal=True,
                                          new_sha256='b' * 64, restored_sha256='b' * 64,
                                          executable_sha256=sha(exe))
                (root / ('build-info-' + system + '.json')).write_text(json.dumps(info))
            output = root.parent / (root.name + '-valid')
            try:
                collect(root, output, source)
                self.assertEqual(len(list(output.iterdir())), 4)
            finally:
                import shutil
                shutil.rmtree(output, ignore_errors=True)
            for mode in ('wrong-source', 'missing', 'corrupt', 'duplicate'):
                info_path = root / 'build-info-linux.json'
                original = info_path.read_bytes()
                duplicate = root / 'nested'
                if mode == 'missing':
                    info_path.unlink()
                elif mode == 'corrupt':
                    info = json.loads(original)
                    info['archive']['sha256'] = '0' * 64
                    info_path.write_text(json.dumps(info))
                elif mode == 'duplicate':
                    duplicate.mkdir()
                    (duplicate / info_path.name).write_bytes(original)
                try:
                    with self.assertRaises(RuntimeError):
                        collect(root, output, 'c' * 40 if mode == 'wrong-source' else source)
                finally:
                    info_path.write_bytes(original)
                    if duplicate.exists():
                        (duplicate / info_path.name).unlink()
                        duplicate.rmdir()


if __name__ == '__main__':
    unittest.main()
