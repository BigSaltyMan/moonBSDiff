"""Build native I/O probes from an isolated source copy with fault injection enabled."""

import argparse
import hashlib
import pathlib
import shutil
import subprocess
import tempfile

from build_cli import ROOT


def copy_cli_sources(folder, *, native_transform=None):
    source = folder / 'source'
    source.mkdir()
    for source_file in ROOT.glob('*.mbt'):
        if not source_file.name.endswith(('_test.mbt', '_wbtest.mbt')):
            shutil.copy2(source_file, source / source_file.name)
    for name in ('moon.mod', 'moon.pkg'):
        shutil.copy2(ROOT / name, source / name)
    for name in ('internal', 'manifest'):
        shutil.copytree(ROOT / name, source / name,
                        ignore=shutil.ignore_patterns('*_test.mbt', '*_wbtest.mbt'))
    shutil.copytree(ROOT / '.mooncakes', source / '.mooncakes')
    cli = source / 'cmd/main'
    cli.mkdir(parents=True)
    identities = {}
    for source_file in (ROOT / 'cmd/main').iterdir():
        if source_file.suffix in ('.mbt', '.c', '.pkg'):
            raw = source_file.read_bytes()
            (cli / source_file.name).write_bytes(raw)
            identities[source_file.name] = hashlib.sha256(raw).hexdigest()

    native = cli / 'native_io.c'
    code = native.read_text(encoding='utf8')
    if native_transform is not None:
        code = native_transform(code)
    native.write_text('#define MBSD_IO_TEST 1\n' + code, encoding='utf8', newline='\n')
    return source, identities


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('contracts', nargs='+', choices=('io', 'stream', 'linux_compat'))
    parser.add_argument('--filter', help='Only run tests matching the given MoonBit test glob')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='native-test-', dir=ROOT / '_build') as folder:
        source, _ = copy_cli_sources(pathlib.Path(folder))
        files = []
        for contract in args.contracts:
            name = f'{contract}_wbtest.mbt'
            path = pathlib.Path('cmd/main') / name
            shutil.copy2(ROOT / 'scripts' / f'{name}.in', source / path)
            files.append(path.as_posix())
        command = ['moon', 'test', *files, '--target', 'native', '--deny-warn']
        if args.filter is not None:
            command.extend(['--filter', args.filter])
        return subprocess.run(command, cwd=source, timeout=150).returncode


if __name__ == '__main__':
    raise SystemExit(main())
