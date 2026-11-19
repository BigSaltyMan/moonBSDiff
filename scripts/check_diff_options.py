"""Commit 25 only: independent streams, one cross-block case and cached bspatch.
No oracle build, old matrix or historical resource measurement is invoked.
"""
import argparse
import json
import math
import re
import os
import pathlib
import platform
import subprocess
import tempfile
import uuid

from build_cli import ROOT
from check_diff import parse, sha
from generation_scale import copy_generation_sources, identities
from oracle_identity import verified_tools
from measure_diff import encoder_identity

RECORD = ROOT/'testdata/generation/compression-options.json'
OLD = b'abracadabra\x00\xff'
NEW = b'abraCHANGED\x00\xffabracadabra!'


def require(ok, why):
    if not ok:
        raise RuntimeError(why)


def verify_record(path):
    r = json.loads(path.read_text(encoding='utf8'))
    require(r['encoder'] == encoder_identity(), 'fixed Writer source differs')
    require(r['sources'] == identities(), 'option evidence production bytes differ')
    require(r['levels'] == list(range(1, 10)) and len(r['measurements']) == 9, 'missing/extra level')
    require(r['input'] == dict(old_size=len(OLD), new_size=len(NEW), old_sha256=sha(OLD), new_sha256=sha(NEW)), 'input identity differs')
    for row, level in zip(r['measurements'], range(1, 10)):
        require(row['level'] == level and row['byte_equal'] is True and row['streams_complete'] is True and
                row['patch_size'] >= 74 and re.fullmatch('[0-9a-f]{64}', row['patch_sha256']) and
                math.isfinite(row['generate_seconds']) and row['generate_seconds'] > 0, 'bad level result')
    require(r['cross']['new_size'] == 100010 and r['cross']['extra_blocks'] == 2 and
            r['cross']['block_count_method'] == 'strict decoder parsed blocks, not marker search' and
            r['cross']['byte_equal'] is True and
            r['cross']['new_sha256'] == sha(bytes(i % 251 for i in range(100010))), 'missing actual cross-block proof')
    require(r['oracle']['cases'] == ['small-level-6', 'cross-level-1'] and r['oracle']['byte_equal'] is True, 'missing nondefault external proof')
    print('Nine option levels, native boundary, source identity and external evidence: PASS')


def evidence(output, oracle, oracle_record=None):
    require(platform.system() == 'Linux', 'native evidence is Linux-only')
    require(not output.exists(), 'refusing to overwrite evidence')
    folder = ROOT/'_build/options-evidence'/('run-'+uuid.uuid4().hex)
    folder.mkdir(parents=True)
    sources = identities()
    encoder = encoder_identity()
    require(encoder == json.loads((ROOT/'testdata/generation/encoder-source.json').read_text(encoding='utf8')), 'fixed encoder identity differs')
    toolchain = subprocess.check_output(['moon', 'version', '--all'], text=True)
    require('moon 0.1.20261102 (ea07287 2026-11-02)' in toolchain and 'moonc v0.10.19+bee578715' in toolchain, 'wrong SDK')
    with tempfile.TemporaryDirectory(prefix='moonbsdiff-options-source-') as tmp:
        snapshot = pathlib.Path(tmp)
        copy_generation_sources(snapshot)
        cache = ROOT/'.mooncakes'; cache.mkdir(exist_ok=True)
        os.symlink(cache, snapshot/'.mooncakes', target_is_directory=True)
        for name, digest in sources.items():
            require(sha((snapshot/name).read_bytes()) == digest, 'source snapshot differs')
        with (snapshot/'moon.pkg').open('a', encoding='utf8') as f:
            f.write('\nimport { "moonbitlang/core/bench" } for "wbtest"\n')
        (snapshot/'options_wbtest.mbt').write_bytes((ROOT/'scripts/diff_options.mbt.in').read_bytes())
        command = ['moon', 'test', 'options_wbtest.mbt', '--target', 'native', '--release', '--deny-warn']
        built = subprocess.run(command+['--build-only'], cwd=snapshot, capture_output=True, timeout=180)
        (folder/'build.log').write_bytes(built.stdout+built.stderr)
        require(built.returncode == 0, 'native evidence build failed: '+(built.stdout+built.stderr).decode(errors='replace'))
        result = subprocess.run(command, cwd=snapshot, capture_output=True, timeout=120)
        (folder/'run.log').write_bytes(result.stdout+result.stderr)
        require(result.returncode == 0, 'native evidence failed: '+(result.stdout+result.stderr).decode(errors='replace'))
    lines = result.stdout.decode().splitlines()
    require(len(lines) == 11 and lines[-1] == 'Total tests: 2, passed: 2, failed: 0.', 'missing/extra native test result')
    rows, patches = [], {}
    for level, line in zip(range(1, 10), lines[:9]):
        tag, actual, micros, encoded = line.split(':')
        require(tag == 'OPTIONS' and int(actual) == level, 'wrong/duplicate level result')
        raw = bytes.fromhex(encoded)
        details = parse(raw, OLD, NEW, level=level)
        patches['small-level-'+str(level)] = (OLD, NEW, raw)
        rows.append(dict(level=level, patch_size=len(raw), patch_sha256=sha(raw), generate_seconds=float(micros)/1000000,
                         byte_equal=True, streams_complete=True, controls=details['control_count']))
    tag, blocks, encoded = lines[9].split(':')
    require(tag == 'CROSS' and int(blocks) == 2, 'missing actual block count')
    cross_new = bytes(i % 251 for i in range(100010)); cross_patch = bytes.fromhex(encoded)
    parse(cross_patch, b'', cross_new, level=1)
    patches['cross-level-1'] = (b'', cross_new, cross_patch)
    external = dict(cases=[], byte_equal=False)
    if oracle:
        tools, identity = verified_tools(oracle_record, required=('bspatch',))
        for name in ['small-level-6', 'cross-level-1']:
            old, new, raw = patches[name]
            work = folder/name; work.mkdir()
            for filename, data in [('old', old), ('new', new), ('patch', raw)]:
                (work/filename).write_bytes(data)
            r = subprocess.run([str(tools['bspatch']), str(work/'old'), str(work/'restored'), str(work/'patch')], capture_output=True, timeout=30)
            require(r.returncode == 0 and (work/'restored').is_file() and (work/'restored').read_bytes() == new, 'upstream restore failed: '+name)
        external = dict(cases=['small-level-6', 'cross-level-1'], byte_equal=True,
                        bspatch_sha256=identity['products']['bspatch'], rebuilt=False)
    report = dict(schema_version=1, sources=sources, encoder=encoder, platform=platform.platform(), architecture=platform.machine(),
                  cpu=next(line.split(':', 1)[1].strip() for line in pathlib.Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),
                  compiler=subprocess.check_output(['cc', '--version'], text=True).splitlines()[0],
                  toolchain=[line[:line.index(')')+1] for line in toolchain.splitlines() if line.startswith(('moon ', 'moonc ', 'moonrun '))],
                  mode='native release; actual public API in byte-identical source snapshot; default compiler flags',
                  timing='one call per level; core monotonic clock around diff_with_options including validation/index/encoding, excluding input construction/apply/assertions/hex/process/build; no warmup; tiny-input noise, not rankings',
                  repeats=1, peak_memory='not measured', levels=list(range(1, 10)),
                  input=dict(old_size=len(OLD), new_size=len(NEW), old_sha256=sha(OLD), new_sha256=sha(NEW)),
                  measurements=rows, cross=dict(level=1, new_size=len(cross_new), new_sha256=sha(cross_new), patch_size=len(cross_patch), patch_sha256=sha(cross_patch),
                                                extra_blocks=2, block_count_method='strict decoder parsed blocks, not marker search', byte_equal=True),
                  oracle=external)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf8', newline='\n')
    print('OPTIONS EVIDENCE '+json.dumps(dict(report=str(output), levels=9, extra_blocks=2, oracle=external,
                                             timings=[row for row in rows if row['level'] in (1, 6, 9)])))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--native-evidence', action='store_true')
    p.add_argument('--oracle', action='store_true')
    p.add_argument('--oracle-record', type=pathlib.Path)
    p.add_argument('--output', type=pathlib.Path)
    p.add_argument('--verify-record', type=pathlib.Path, nargs='?', const=RECORD)
    a = p.parse_args()
    if a.native_evidence:
        require(a.output is not None, '--output required')
        require(a.oracle or a.oracle_record is None, '--oracle-record requires --oracle')
        evidence(a.output, a.oracle, a.oracle_record)
    elif a.verify_record:
        verify_record(a.verify_record)
    else:
        p.error('choose --native-evidence or --verify-record')
