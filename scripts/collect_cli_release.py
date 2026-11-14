"""Verify exactly two CI distributions and collect four public CLI assets.

This does not execute the CLI again, build, publish, or touch Mooncakes.
"""
import argparse
import io
import json
import pathlib
import re
import tarfile
import zipfile

from package_cli import require, sha


def collect(folder, output, source_sha):
    require(re.fullmatch(r'[0-9a-f]{40}', source_sha), 'invalid source SHA')
    require(not output.exists(), 'collection output already exists')
    records, assets = [], {}
    required = {'build-info-windows.json', 'build-info-linux.json',
                'moonbsdiff-0.2.0-windows-x86_64.zip', 'moonbsdiff-0.2.0-linux-x86_64.tar.gz'}
    files = [p for p in folder.rglob('*') if p.is_file()]
    require(len(files) == len(required) and {p.name for p in files} == required,
            'missing, duplicate or unexpected platform artifact')
    by_name = {p.name: p for p in files}
    for system in ('linux', 'windows'):
        info = json.loads(by_name['build-info-' + system + '.json'].read_text(encoding='utf8'))
        require(info['schema_version'] == 1 and info['version'] == '0.2.0' and
                info['platform'] == system and info['architecture'] == 'x86_64' and
                info['source_sha'] == source_sha and info['build_mode'] == 'native release', 'platform/source identity mismatch')
        validation = info['validation']
        require(validation['help'] is True and validation['exact_version'] == '0.2.0' and
                validation['byte_equal'] is True and validation['new_sha256'] == validation['restored_sha256'] and
                validation['executable_sha256'] == info['executable']['sha256'], 'missing archive validation')
        archive_info = info['archive']
        archive_name = 'moonbsdiff-0.2.0-' + system + '-x86_64' + ('.zip' if system == 'windows' else '.tar.gz')
        require(archive_info['name'] == archive_name, 'wrong archive name')
        raw = by_name[archive_name].read_bytes()
        require(len(raw) == archive_info['size_bytes'] and sha(raw) == archive_info['sha256'], 'archive hash/size mismatch')
        exe_name = 'moonbsdiff.exe' if system == 'windows' else 'moonbsdiff'
        if system == 'windows':
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                exe = archive.read(exe_name)
                embedded = json.loads(archive.read('build-source.json'))
        else:
            with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
                exe = archive.extractfile(exe_name).read()
                embedded = json.loads(archive.extractfile('build-source.json').read())
        require(embedded == {k: v for k, v in info.items() if k not in ('archive', 'validation')}, 'embedded provenance differs')
        require(sha(exe) == info['executable']['sha256'] and len(exe) == info['executable']['size_bytes'], 'executable identity mismatch')
        records.append(info)
        assets[archive_name] = raw
    output.mkdir(parents=True)
    for name, raw in assets.items():
        (output / name).write_bytes(raw)
    combined = dict(schema_version=1, version='0.2.0', source_sha=source_sha, distributions=records,
                    ci_run_id=__import__('os').environ.get('GITHUB_RUN_ID'), mooncakes_0_2_0_published=False)
    assets['build-info.json'] = (json.dumps(combined, indent=2) + '\n').encode()
    (output / 'build-info.json').write_bytes(assets['build-info.json'])
    (output / 'SHA256SUMS').write_text(''.join(sha(raw) + '  ' + name + '\n' for name, raw in sorted(assets.items())), encoding='utf8', newline='\n')
    return combined


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input', type=pathlib.Path, required=True)
    p.add_argument('--output', type=pathlib.Path, required=True)
    p.add_argument('--source-sha', required=True)
    a = p.parse_args()
    report = collect(a.input, a.output, a.source_sha)
    print('CLI RELEASE ASSETS ' + json.dumps(dict(source_sha=report['source_sha'],
                                                platforms=[r['platform'] for r in report['distributions']])))
