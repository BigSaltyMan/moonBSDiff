"""Build a clean-SHA native release, archive it, and run only the unpacked CLI.

No publication, registry upload, or historical test suites are performed.
"""
import argparse
import hashlib
import io
import json
import os
import pathlib
import platform
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import zipfile

from build_cli import ROOT, host_arch, host_platform, version

SUPPORTED_TARGETS = (
    ('windows', 'x86_64'),
    ('linux', 'x86_64'),
    ('linux', 'arm64'),
    ('macos', 'arm64'),
)
PRIVATE_IO_SYMBOLS = frozenset({
    'mbsd_test_fault',
    'mbsd_io_contract',
    'mbsd_stream_contract',
    'mbsd_interrupt_test_setup',
    'mbsd_compat_contract',
})
MBSD_SYMBOL_RE = re.compile(r'(?:^|[\s:])_?(mbsd_[A-Za-z0-9_]+)\b', re.M)


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, timeout=300, **kwargs)
    require(result.returncode == 0, 'command failed: ' + str(args) + '\n' +
            result.stderr.decode('utf8', errors='replace'))
    return result.stdout.decode('utf8', errors='replace')


def find_private_mbsd_symbols(symbols):
    return sorted(PRIVATE_IO_SYMBOLS.intersection(MBSD_SYMBOL_RE.findall(symbols)))


def inspect_elf_header(raw, arch):
    require(len(raw) >= 20 and raw[:4] == b'\x7fELF', 'not an ELF executable')
    require(raw[4] == 2 and raw[5] == 1, 'not ELF64 little-endian')
    e_machine = struct.unpack_from('<H', raw, 18)[0]
    expected = {'x86_64': 62, 'arm64': 183}
    require(arch in expected, f'unsupported ELF architecture: {arch}')
    require(e_machine == expected[arch],
            f'ELF e_machine {e_machine} does not match expected {arch} ({expected[arch]})')
    return e_machine


def inspect_macho_header(raw, arch):
    require(len(raw) >= 4, 'truncated Mach-O header')
    magic = struct.unpack_from('<I', raw, 0)[0]
    require(magic not in (0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca),
            'unexpected universal/fat Mach-O binary')
    require(len(raw) >= 32 and magic == 0xfeedfacf, 'not a 64-bit little-endian Mach-O binary')
    _, cputype, _, filetype = struct.unpack_from('<IIII', raw, 0)
    require(filetype == 2, f'unexpected Mach-O filetype {filetype} (expected MH_EXECUTE=2)')
    expected = {'arm64': 0x0100000c, 'x86_64': 0x01000007}
    require(arch in expected, f'unsupported Mach-O architecture: {arch}')
    require(cputype == expected[arch],
            f'Mach-O cputype {cputype:#x} does not match expected {arch} ({expected[arch]:#x})')
    return cputype


def validate_macos_dylibs(otool_output):
    dylibs = []
    for raw_line in otool_output.splitlines():
        if not raw_line.strip():
            continue
        if not raw_line[0].isspace() and raw_line.rstrip().endswith(':'):
            continue
        dep = raw_line.strip().split(' (', 1)[0].strip()
        require(dep.startswith(('/usr/lib/', '/System/Library/')),
                f'non-system macOS dylib dependency: {dep}')
        parts = pathlib.PurePosixPath(dep).parts
        require('..' not in parts, f'unsafe macOS dylib path: {dep}')
        dylibs.append(dep)
    require(dylibs, 'missing macOS dylib dependencies in otool -L output')
    return sorted(set(dylibs))


def check_test_exports(exe, system):
    """Check the actual release image and its native adapter if ELF/Mach-O is stripped."""
    def check(path, table, symbols):
        found = find_private_mbsd_symbols(symbols)
        require(not found, f'{path} {table} contains private I/O symbols: {found}')
        print(f'{path}: {table} contains none of the {len(PRIVATE_IO_SYMBOLS)} private I/O symbols')

    def has_deliver(symbols):
        return 'mbsd_deliver' in MBSD_SYMBOL_RE.findall(symbols)

    if system == 'windows':
        exports = run(['dumpbin', '/exports', str(exe)])
        require(has_deliver(exports), 'expected native PE export missing')
        check(exe, 'PE export table', exports)
    elif system == 'macos':
        check(exe, 'Mach-O global symbols', run(['nm', '-gU', str(exe)]))
        regular = run(['nm', '-U', str(exe)])
        if regular.strip():
            check(exe, 'Mach-O ordinary symbols', regular)
        if not has_deliver(regular):
            obj = ROOT / '_build/cli-macos/native/release/build/cmd/main/native_io.o'
            symbols = run(['nm', '-U', str(obj)])
            require(has_deliver(symbols), 'expected native object symbol missing')
            check(obj, 'Mach-O ordinary symbols (release adapter object)', symbols)
    else:
        check(exe, 'ELF dynamic symbols', run(['nm', '-D', '--defined-only', str(exe)]))
        regular = run(['nm', '--defined-only', str(exe)])
        if regular.strip():
            check(exe, 'ELF ordinary symbols', regular)
        if not has_deliver(regular):
            # The same release build retains the unstripped native adapter object.
            obj = ROOT / '_build/cli-linux/native/release/build/cmd/main/native_io.o'
            symbols = run(['nm', '--defined-only', str(obj)])
            require(has_deliver(symbols), 'expected native object symbol missing')
            check(obj, 'ELF ordinary symbols (release adapter object)', symbols)


def metadata(exe, system, arch):
    if system == 'windows':
        headers = run(['dumpbin', '/headers', str(exe)])
        require(re.search(r'8664 machine \(x64\)', headers, re.I), 'not PE x86_64')
        imports = run(['dumpbin', '/dependents', str(exe)])
        dlls = sorted(set(re.findall(r'^\s+([\w.\-]+\.dll)\s*$', imports, re.M | re.I)))
        require(dlls, 'empty PE imports')
        # Do not silently distribute an executable needing an unbundled VC runtime.
        # System UCRT/API-set/MSVCRT imports are resolved by supported Windows.
        require(not any(re.match(r'(vcruntime|msvcp|concrt)', d, re.I) for d in dlls),
                'non-system VC runtime requires an explicit licensed distribution policy')
        compiler = subprocess.run(['cl'], capture_output=True, timeout=15)
        compiler_text = (compiler.stdout + compiler.stderr).decode('utf8', errors='replace')
        require('Compiler Version' in compiler_text, 'MSVC compiler identity missing')
        compiler_version = next(line.strip() for line in compiler_text.splitlines() if 'Compiler Version' in line)
        return dict(format='PE32+ x86_64', dll_imports=dlls,
                    compiler=compiler_version,
                    runtime_scope='Tested on this Windows runner; no universal minimum Windows version claimed')
    if system == 'macos':
        inspect_macho_header(exe.read_bytes(), arch)
        lipo_info = run(['lipo', '-info', str(exe)])
        require('Non-fat file:' in lipo_info, 'unexpected universal/fat Mach-O binary')
        require(arch in lipo_info, f'unexpected lipo architecture for {arch}: {lipo_info}')
        dylibs = validate_macos_dylibs(run(['otool', '-L', str(exe)]))
        load_cmds = run(['otool', '-l', str(exe)])
        require(not re.search(r'\bcmd\s+LC_RPATH\b', load_cmds), 'embedded LC_RPATH in Mach-O binary')
        return dict(format=f'Mach-O 64-bit {arch}', dylibs=dylibs,
                    compiler=run(['cc', '--version']).splitlines()[0],
                    macos_version=run(['sw_vers', '-productVersion']).strip(),
                    runtime_scope='Dynamically linked against macOS system libraries only; no universal OS version guarantee')
    inspect_elf_header(exe.read_bytes(), arch)
    header = run(['readelf', '-h', str(exe)])
    expected_machine = 'Advanced Micro Devices X86-64' if arch == 'x86_64' else 'AArch64'
    require(expected_machine in header, f'not ELF {arch}')
    program = run(['readelf', '-l', str(exe)])
    dynamic = run(['readelf', '-d', str(exe)])
    versions = run(['readelf', '--version-info', str(exe)])
    interpreter = re.findall(r'Requesting program interpreter: ([^\]]+)', program)
    needed = sorted(set(re.findall(r'\(NEEDED\).*\[([^\]]+)\]', dynamic)))
    glibc = sorted(set(re.findall(r'\bGLIBC_([0-9.]+)\b', versions)),
                   key=lambda s: tuple(map(int, s.split('.'))))
    require(len(interpreter) == 1 and needed and glibc, 'missing dynamic runtime identity')
    require(interpreter[0].startswith('/lib') and all('/' not in n for n in needed),
            'unexpected loader or absolute shared-library path')
    require(not re.search(r'\((RPATH|RUNPATH)\)', dynamic), 'embedded runtime search path')
    resolved = run(['ldd', str(exe)])
    require('not found' not in resolved, 'unresolved runtime dependency')
    return dict(format=f'ELF64 {arch}', interpreter=interpreter[0], needed=needed,
                required_glibc_symbols=glibc, highest_required_glibc_symbol='GLIBC_' + glibc[-1],
                compiler=run(['cc', '--version']).splitlines()[0],
                build_libc=run(['ldd', '--version']).splitlines()[0],
                os_release=pathlib.Path('/etc/os-release').read_text(),
                runtime_scope='Dynamically linked; symbol requirement is not a tested minimum distribution guarantee')


def archive_bytes(files, system, epoch):
    """One flat product directory; file bytes/modes are checked after extraction."""
    output = io.BytesIO()
    if system == 'windows':
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, raw in sorted(files.items()):
                info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                archive.writestr(info, raw)
    else:
        # Fixed metadata does not imply that compiler outputs are reproducible.
        import gzip
        with gzip.GzipFile(fileobj=output, mode='wb', mtime=epoch, filename='') as gz:
            with tarfile.open(fileobj=gz, mode='w') as archive:
                for name, raw in sorted(files.items()):
                    info = tarfile.TarInfo(name)
                    info.size = len(raw)
                    info.mode = 0o755 if name == 'moonbsdiff' else 0o644
                    info.mtime = epoch
                    archive.addfile(info, io.BytesIO(raw))
    return output.getvalue()


def unpack_check(path, expected, dest, system):
    if system == 'windows':
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)) and set(names) == set(expected), 'ZIP members differ')
            require(archive.testzip() is None, 'ZIP CRC failure')
            for name in names:
                require('/' not in name and '\\' not in name and name not in ('.', '..'), 'unsafe member')
                (dest / name).write_bytes(archive.read(name))
    else:
        with tarfile.open(path, 'r:gz') as archive:
            members = archive.getmembers()
            require(len(members) == len(expected) and {m.name for m in members} == set(expected), 'tar members differ')
            for member in members:
                require(member.isfile() and '/' not in member.name and '\\' not in member.name and
                        member.name not in ('.', '..'), 'unsafe member')
                if member.name == 'moonbsdiff':
                    require(member.mode & 0o111, 'missing executable mode in tar archive')
                target = dest / member.name
                target.write_bytes(archive.extractfile(member).read())
                target.chmod(member.mode)
    for name, raw in expected.items():
        require((dest / name).read_bytes() == raw, 'unpacked member differs: ' + name)
    if system != 'windows' and os.name != 'nt':
        require((dest / 'moonbsdiff').stat().st_mode & 0o111, 'lost executable permission')


def smoke(exe, folder, expected_version):
    # Binary dependency inspection is the primary runtime check. Also remove
    # SDK/compiler/Python search paths while executing the actual archived binary.
    env = dict(os.environ)
    env.pop('MOON_HOME', None)
    env.pop('LD_LIBRARY_PATH', None)
    env.pop('LD_PRELOAD', None)
    env.pop('DYLD_LIBRARY_PATH', None)
    env.pop('DYLD_FALLBACK_LIBRARY_PATH', None)
    env.pop('DYLD_INSERT_LIBRARIES', None)
    env['PATH'] = str(pathlib.Path(os.environ['SystemRoot']) / 'System32') if os.name == 'nt' else '/usr/bin:/bin'
    help_text = run([str(exe), '--help'], cwd=folder, env=env)
    require(all(command in help_text for command in ['diff', 'patch', 'verify', 'inspect']), 'incomplete CLI help')
    require(run([str(exe), '--version'], cwd=folder, env=env).strip() == 'moonbsdiff ' + expected_version,
            'wrong archived CLI version')
    old, new = b'abc\x00\xff', b'abC\x00\xff!'
    (folder / 'old.bin').write_bytes(old)
    (folder / 'new.bin').write_bytes(new)
    commands = [['diff', '--manifest', 'update.json', 'old.bin', 'new.bin', 'update.patch'],
                ['patch', '--manifest', 'update.json', 'old.bin', 'update.patch', 'restored.bin']]
    for args in commands:
        require(not run([str(exe), *args], cwd=folder, env=env), 'unexpected successful-operation stdout')
    require((folder / 'restored.bin').read_bytes() == new, 'archive roundtrip mismatch')
    streamed = subprocess.run([str(exe), 'patch', '--stream', '--progress', 'json', 'old.bin', 'update.patch', 'streamed.bin'], cwd=folder,env=env,capture_output=True,timeout=30)
    require(streamed.returncode==0 and not streamed.stdout,'archived stream execution failed')
    events=[json.loads(line) for line in streamed.stderr.decode('utf8').splitlines()]
    require(events and events[-1]['event']=='complete' and events[-1]['output_committed'] is True and (folder/'streamed.bin').read_bytes()==new,'archived stream result differs')
    manifest = json.loads((folder / 'update.json').read_bytes())
    require(manifest['producer']['version'] == expected_version, 'wrong manifest producer version')
    for key, raw in [('old', old), ('new', new), ('patch', (folder / 'update.patch').read_bytes())]:
        require(manifest[key] == dict(size_bytes=str(len(raw)), sha256=sha(raw)), 'manifest identity mismatch')
    require((folder / 'old.bin').read_bytes() == old and (folder / 'new.bin').read_bytes() == new, 'input changed')
    return dict(help=True, exact_version=expected_version, commands=commands, byte_equal=True, stream_json_complete=True,
                new_sha256=sha(new), restored_sha256=sha((folder / 'restored.bin').read_bytes()),
                sdk_path_removed=True, executable_sha256=sha(exe.read_bytes()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '_build/cli-dist')
    args = parser.parse_args()
    system = host_platform()
    arch = host_arch()
    require((system, arch) in SUPPORTED_TARGETS, f'unsupported release host: {system} {arch}')
    git = ['git', '-c', 'safe.directory=' + ROOT.as_posix()]
    source = run(git + ['rev-parse', 'HEAD'], cwd=ROOT).strip()
    dirty = run(git + ['status', '--porcelain', '--untracked-files=no'], cwd=ROOT)
    require(not dirty, 'tracked source is not clean:\n' + dirty)
    require(not os.environ.get('GITHUB_SHA') or os.environ['GITHUB_SHA'] == source, 'workflow/source SHA mismatch')
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version()), 'invalid distribution version')
    sdk = pathlib.Path(os.environ['MOON_HOME']) if os.environ.get('MOON_HOME') else pathlib.Path(shutil.which('moon')).resolve().parent.parent
    toolchain = run(['moon', 'version', '--all'], cwd=ROOT)
    require('moon 0.1.20261126 (ccd306a 2026-11-26)' in toolchain and 'moonc v1.0.0-rc1+3c0520448' in toolchain, 'wrong SDK')
    run([sys.executable, str(ROOT / 'scripts/build_cli.py'), '--release'], cwd=ROOT)
    require(not run(git + ['status', '--porcelain', '--untracked-files=no'], cwd=ROOT), 'release build changed tracked source')
    exe_name = 'moonbsdiff.exe' if system == 'windows' else 'moonbsdiff'
    exe = ROOT / '_build/bin' / system / exe_name
    check_test_exports(exe, system)
    dependencies = metadata(exe, system, arch)
    licenses = {'LICENSE': (ROOT / 'LICENSE').read_bytes(),
                'BSDIFF-LICENSE.txt': (ROOT / 'tools/oracle/BSDIFF-LICENSE.txt').read_bytes(),
                'Apache-2.0.txt': (ROOT / 'internal/bzip2/LICENSE').read_bytes(),
                'core-NOTICE.txt': (sdk / 'lib/core/NOTICE').read_bytes(),
                'SDK-CREDITS.txt': (ROOT / 'docs/cli-sdk-credits.txt').read_bytes()}
    attribution = ['MoonBSDiff: BSD-2-Clause, see LICENSE.',
                   'BSDiff 4.3 derived matching/scan: Copyright 2003-2005 Colin Percival; see BSDIFF-LICENSE.txt.',
                   'MoonBit core/runtime: Copyright 2026 International Digital Economy Academy; Apache-2.0; see core-NOTICE.txt.',
                   'Adapted decoder: Copyright 2026 Leo Cheng, moonzip 0.3.5; Apache-2.0; source changes in repository internal/bzip2/.']
    dependency_versions = {}
    for module in sorted((ROOT / '.mooncakes/moonbitstack').iterdir()):
        if not (module / 'moon.mod').is_file():
            continue
        text = (module / 'moon.mod').read_text(encoding='utf8')
        module_version = re.search(r'^version\s*=\s*"([^"]+)"', text, re.M)[1]
        raw = (module / 'LICENSE').read_bytes()
        require(b'Apache License' in raw, 'unexpected dependency license')
        dependency_versions[module.name] = module_version
        attribution.append('moonbitstack/' + module.name + '@' + module_version + ': Apache-2.0; source https://github.com/moonbitstack/' + module.name)
        if (module / 'NOTICE').exists():
            licenses[module.name + '-NOTICE.txt'] = (module / 'NOTICE').read_bytes()
    require(dependency_versions.get('moonzip') == '0.3.5' and dependency_versions.get('mooncrypt') == '0.4.7', 'wrong direct dependency')
    info = dict(schema_version=1, version=version(), source_sha=source, platform=system, architecture=arch,
                build_mode='native release', build_command='python scripts/build_cli.py --release',
                toolchain=[re.match(r'^((?:moon|moonc|moonrun) .+?\))', line)[1]
                           for line in toolchain.splitlines() if re.match(r'^(moon |moonc |moonrun )', line)],
                dependencies=dependency_versions, runtime=dependencies,
                executable=dict(name=exe_name, size_bytes=exe.stat().st_size, sha256=sha(exe.read_bytes())),
                runner_image=os.environ.get('ImageOS'), runner_image_version=os.environ.get('ImageVersion'),
                host=dict(system=platform.system(), release=platform.release(), architecture=platform.machine()),
                licenses={name: sha(raw) for name, raw in licenses.items()},
                registry_publication_verified_by_build=False, bit_reproducibility_claimed=False)
    files = {exe_name: exe.read_bytes(), **licenses,
             'THIRD-PARTY.txt': ('\n'.join(attribution) + '\n').encode(),
             'build-source.json': (json.dumps(info, indent=2) + '\n').encode(),
             'README.txt': (f'MoonBSDiff CLI {version()} ({system} {arch})\n'
                            'Supports Windows x86_64, Linux x86_64/arm64, and macOS arm64.\n'
                            'Extract into a directory you choose. No administrator/PATH changes required.\n'
                            f'Run {exe_name} --help or --version.\n'
                            'diff --manifest update.json OLD NEW PATCH\n'
                            'patch --manifest update.json OLD PATCH OUTPUT\n'
                            'Outputs are never overwritten; patch+manifest are not a multi-file transaction.\n'
                            'Manifest hashes do not authenticate a publisher. Use trusted expected hashes.\n'
                            'Linux prefers O_TMPFILE+/proc; macOS and guarded local-ext fallback use 0700 private staging and protected parent permissions.\n'
                            'No universal filesystem/platform, CPU, peak-memory or durability guarantee.\n'
                            'See build-source.json for actual runtime imports and build environment.\n'
                            'Registry publication is verified separately from this binary build.\n'
                            f'https://github.com/BigSaltyMan/moonBSDiff/blob/v{version()}/docs/cli-install.md\n').encode()}
    output = args.output.resolve()
    require(not output.exists(), 'output directory exists; choose a fresh distribution directory')
    output.mkdir(parents=True)
    extension = '.zip' if system == 'windows' else '.tar.gz'
    archive = output / f'moonbsdiff-{version()}-{system}-{arch}{extension}'
    epoch = int(run(git + ['show', '-s', '--format=%ct', source], cwd=ROOT).strip())
    archive.write_bytes(archive_bytes(files, system, epoch))
    # POSIX IO should use the host's real local temp filesystem, not a checkout
    # on a Windows-mounted drive. No fallback hook is enabled.
    with tempfile.TemporaryDirectory(prefix='moonbsdiff-unpacked-') as temp:
        unpacked = pathlib.Path(temp)
        unpack_check(archive, files, unpacked, system)
        validation = smoke(unpacked / exe_name, unpacked, version())
    info['archive'] = dict(name=archive.name, size_bytes=archive.stat().st_size, sha256=sha(archive.read_bytes()))
    info['validation'] = validation
    (output / f'build-info-{system}-{arch}.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf8')
    print('CLI DISTRIBUTION ' + json.dumps(dict(source_sha=source, archive=info['archive'], validation=validation)))


if __name__ == '__main__':
    main()
