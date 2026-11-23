"""Small archive/provenance gate tests; synthetic records are not runtime evidence."""
import json
import pathlib
import shutil
import struct
import tempfile
import unittest
from unittest import mock

from collect_cli_release import RELEASE_TARGETS, collect
from build_cli import version
from package_cli import (
    MBSD_SYMBOL_RE,
    SUPPORTED_TARGETS,
    archive_bytes,
    check_test_exports,
    find_private_mbsd_symbols,
    inspect_elf_header,
    inspect_macho_header,
    sha,
    unpack_check,
    validate_macos_dylibs,
)


def make_elf64_header(e_machine, *, elf_class=2, elf_data=1):
    ident = b'\x7fELF' + bytes([elf_class, elf_data, 1, 0]) + b'\x00' * 8
    return ident + struct.pack('<HHIQQQIHHHHHH', 3, e_machine, 1, 0, 64, 0, 0, 64, 56, 0, 64, 0, 0)


def make_macho64_header(cputype, *, magic=0xfeedfacf, filetype=2):
    return struct.pack('<IIIIIIII', magic, cputype, 0, filetype, 0, 0, 0, 0)


class DistributionTests(unittest.TestCase):
    def test_archive_members_bytes_and_executable_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            for system in ('linux', 'windows', 'macos'):
                files = {'moonbsdiff.exe' if system == 'windows' else 'moonbsdiff': b'synthetic binary', 'LICENSE': b'notice'}
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
            for system, arch in SUPPORTED_TARGETS:
                exe_name = 'moonbsdiff.exe' if system == 'windows' else 'moonbsdiff'
                exe = f'synthetic {system} {arch} binary'.encode()
                info = dict(schema_version=1, version=version(), platform=system, architecture=arch,
                            source_sha=source, build_mode='native release',
                            executable=dict(size_bytes=len(exe), sha256=sha(exe)))
                ext = '.zip' if system == 'windows' else '.tar.gz'
                name = f'moonbsdiff-{version()}-{system}-{arch}{ext}'
                raw = archive_bytes({exe_name: exe, 'build-source.json': json.dumps(info).encode()}, system, 1)
                (root / name).write_bytes(raw)
                info['archive'] = dict(name=name, size_bytes=len(raw), sha256=sha(raw))
                info['validation'] = dict(help=True, exact_version=version(), byte_equal=True, stream_json_complete=True,
                                          new_sha256='b' * 64, restored_sha256='b' * 64,
                                          executable_sha256=sha(exe))
                (root / f'build-info-{system}-{arch}.json').write_text(json.dumps(info))
            self.assertEqual(set(SUPPORTED_TARGETS), set(RELEASE_TARGETS))
            self.assertEqual(len(RELEASE_TARGETS), 4)
            output = root.parent / (root.name + '-valid')
            try:
                collect(root, output, source)
                self.assertEqual(len(list(output.iterdir())), 6)
                sums = (output / 'SHA256SUMS').read_text(encoding='utf8').splitlines()
                self.assertEqual(len(sums), 5)
                combined = json.loads((output / 'build-info.json').read_text(encoding='utf8'))
                self.assertEqual(len(combined['distributions']), 4)
            finally:
                shutil.rmtree(output, ignore_errors=True)
            for mode in ('wrong-source', 'missing', 'corrupt', 'duplicate'):
                info_path = root / 'build-info-linux-x86_64.json'
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

    def test_inspect_elf_header(self):
        x64 = make_elf64_header(62)
        arm64 = make_elf64_header(183)
        self.assertEqual(inspect_elf_header(x64, 'x86_64'), 62)
        self.assertEqual(inspect_elf_header(arm64, 'arm64'), 183)
        with self.assertRaises(RuntimeError):
            inspect_elf_header(x64, 'arm64')
        with self.assertRaises(RuntimeError):
            inspect_elf_header(arm64, 'x86_64')
        with self.assertRaises(RuntimeError):
            inspect_elf_header(make_elf64_header(62, elf_class=1), 'x86_64')
        with self.assertRaises(RuntimeError):
            inspect_elf_header(b'not-elf', 'x86_64')

    def test_inspect_macho_header(self):
        arm64 = make_macho64_header(0x0100000c)
        x64 = make_macho64_header(0x01000007)
        self.assertEqual(inspect_macho_header(arm64, 'arm64'), 0x0100000c)
        self.assertEqual(inspect_macho_header(x64, 'x86_64'), 0x01000007)
        with self.assertRaises(RuntimeError):
            inspect_macho_header(arm64, 'x86_64')
        with self.assertRaises(RuntimeError):
            inspect_macho_header(x64, 'arm64')
        for fat_magic in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'):
            with self.assertRaises(RuntimeError):
                inspect_macho_header(fat_magic + b'\x00' * 28, 'arm64')
        with self.assertRaises(RuntimeError):
            inspect_macho_header(make_macho64_header(0x0100000c, filetype=1), 'arm64')

    def test_macho_leading_underscore_symbol_detection(self):
        clean_nm = '0000000100003a20 T _mbsd_deliver\n0000000100003b00 T _mbsd_random_bytes\n'
        self.assertEqual(find_private_mbsd_symbols(clean_nm), [])
        self.assertIn('mbsd_deliver', MBSD_SYMBOL_RE.findall(clean_nm))
        self.assertIn('mbsd_random_bytes', MBSD_SYMBOL_RE.findall(clean_nm))
        for sym in ('mbsd_test_fault', 'mbsd_io_contract', 'mbsd_stream_contract',
                    'mbsd_interrupt_test_setup', 'mbsd_compat_contract'):
            for line in (f'0000000100004000 T _{sym}\n', f'_{sym}\n', f'foo: _{sym}\n', f'00001000 T {sym}\n'):
                self.assertEqual(find_private_mbsd_symbols(line), [sym])

    def test_validate_macos_dylibs(self):
        valid = (
            'moonbsdiff:\n'
            '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)\n'
            '\t/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation (compatibility version 150.0.0, current version 2420.0.0)\n'
        )
        self.assertEqual(len(validate_macos_dylibs(valid)), 2)
        for bad_dep in (
            '\t/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib (compatibility version 3.0.0, current version 3.0.0)\n',
            '\t@rpath/libcustom.dylib (compatibility version 1.0.0, current version 1.0.0)\n',
            '\t/usr/local/lib/libfoo.dylib (compatibility version 1.0.0, current version 1.0.0)\n',
            '\t/usr/lib/../../opt/homebrew/lib/libfoo.dylib (compatibility version 1.0.0, current version 1.0.0)\n',
        ):
            with self.assertRaises(RuntimeError):
                validate_macos_dylibs('moonbsdiff:\n' + bad_dep)
        with self.assertRaises(RuntimeError):
            validate_macos_dylibs('moonbsdiff:\n')

    def test_check_test_exports_macos_stripped_fallback(self):
        exe = pathlib.Path('/tmp/moonbsdiff')
        header_only = '0000000100000000 T __mh_execute_header\n'
        clean_obj = '0000000000000000 T _mbsd_deliver\n0000000000000040 T _mbsd_random_bytes\n'
        dirty_obj = clean_obj + '0000000000000080 T _mbsd_test_fault\n'

        with mock.patch('package_cli.run', side_effect=[header_only, header_only, clean_obj]) as mocked:
            check_test_exports(exe, 'macos')
            self.assertEqual(mocked.call_count, 3)
            self.assertEqual(mocked.call_args_list[0].args[0], ['nm', '-gU', str(exe)])
            self.assertEqual(mocked.call_args_list[1].args[0], ['nm', '-U', str(exe)])
            self.assertTrue(mocked.call_args_list[2].args[0][2].endswith('native_io.o'))

        with mock.patch('package_cli.run', side_effect=[header_only, header_only, dirty_obj]):
            with self.assertRaisesRegex(RuntimeError, 'mbsd_test_fault'):
                check_test_exports(exe, 'macos')

        with mock.patch('package_cli.run', side_effect=[header_only, header_only, '']):
            with self.assertRaisesRegex(RuntimeError, 'expected native object symbol missing'):
                check_test_exports(exe, 'macos')


if __name__ == '__main__':
    unittest.main()
