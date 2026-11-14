"""Bounded native-release scale evidence and public CLI replay; no old suites.

Measurement copies production bytes into an isolated test snapshot, adds only
wbtest imports for the pinned core clock/existing SHA-256, and removes it finally.
"""
import argparse
import hashlib
import json
import math
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from conformance_cases import lcg, sha
from build_cli import ROOT

KINDS = ['sparse', 'periodic', 'random']
SIZES = {'256k': 262144, '1m': 1048576}
RECORD = ROOT / 'testdata/generation/scales.json'


def require(ok, why):
    if not ok:
        raise RuntimeError(why)


def policy(n):
    return dict(max_old_bytes=n, max_new_bytes=n, max_output_bytes=n,
                max_patch_bytes=2*n, max_decompressed_bytes=n+24*(n//64),
                max_control_instructions=n//64, max_sort_work=200*(n+1), max_match_work=256*n)


def inputs(n, kind):
    old = bytes(i % 7 for i in range(n)) if kind == 'periodic' else lcg(2026112301+n, n)
    if kind == 'sparse':
        new = bytearray(old)
        for at in [n//7, n//3, n//2, n-1]:
            new[at] ^= 85
        new = bytes(new)
    elif kind == 'periodic':
        new = bytes((i+3) % 7 for i in range(n))
    else:
        new = lcg(2026112303+n, n)
    return old, new


def production():
    return sorted([p for p in ROOT.glob('*.mbt') if not p.name.endswith(('_test.mbt', '_wbtest.mbt'))])


def identities():
    files = production()+sorted((ROOT/'internal/bzip2').glob('*.mbt'))+[ROOT/'moon.mod', ROOT/'moon.pkg']
    return {p.relative_to(ROOT).as_posix(): sha(p.read_bytes()) for p in files}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2)+'\n', encoding='utf8', newline='\n')


def verify(report, current=False):
    require(report['schema_version'] == 1, 'unsupported evidence schema')
    if current:
        require(report['sources'] == identities(), 'measured production source bytes differ')
    stages = report['stages']
    require(stages in (['256k'], ['256k', '1m']), 'missing/out-of-order stage')
    require(len(report['measurements']) == len(stages)*3, 'missing/extra measurement')
    for row, (stage, kind) in zip(report['measurements'], [(s, k) for s in stages for k in KINDS]):
        n = SIZES[stage]
        old, new = inputs(n, kind)
        require(row['id'] == stage+'-'+kind and row['limits'] == policy(n), 'case/policy differs')
        require(row['old_size'] == n and row['new_size'] == n and row['old_sha256'] == sha(old)
                and row['new_sha256'] == sha(new) == row['restored_sha256'], 'input/restored identity differs')
        require(row['byte_equal'] is True and row['inputs_unchanged'] is True, 'missing content assertions')
        require(0 < row['sort_work'] <= policy(n)['max_sort_work'] and
                0 < row['match_work'] <= policy(n)['max_match_work'], 'invalid work counts')
        require(row['raw_diff_bytes']+row['raw_extra_bytes'] == n and row['raw_control_bytes'] % 24 == 0
                and row['control_count'] == row['raw_control_bytes']//24, 'invalid raw data counts')
        require(row['raw_total_bytes'] == n+row['raw_control_bytes'] <= policy(n)['max_decompressed_bytes']
                and row['control_count'] <= policy(n)['max_control_instructions'], 'raw/control quota exceeded')
        require(74 <= row['patch_bytes'] <= policy(n)['max_patch_bytes'] and
                re.fullmatch('[0-9a-f]{64}', row['patch_sha256']), 'patch identity/limit invalid')
        require(all(math.isfinite(row[k]) and row[k] > 0 for k in ('generate_seconds', 'apply_seconds', 'process_seconds')), 'invalid timing')
        require(sum(row['match_work_breakdown'].values()) == row['match_work'] and
                all(v >= 0 for v in row['match_work_breakdown'].values()), 'phase accounting differs')
        raw = row['raw_total_bytes']
        control = row['control_count']
        feeds = sum((row[k]+32767)//32768 for k in ('raw_control_bytes', 'raw_diff_bytes', 'raw_extra_bytes'))+3
        require(row['match_work_breakdown']['raw_validation_encoding'] == 4*raw+2*control and
                row['match_work_breakdown']['compression_wrapper'] == feeds+2*(row['patch_bytes']-32) and
                row['match_work_breakdown']['final_assembly'] == 3*row['patch_bytes'], 'derived phase formula differs')
        require(row['sort_initialization_work'] == 5*(n+1) and
                row['sort_round_work'] == row['sort_work']-5*(n+1) > 0 and
                type(row['invocation_max_rss_kib']) is int and row['invocation_max_rss_kib'] > 0, 'invalid initialization/round/RSS evidence')
    require(report['low_quota_probe'] == dict(stage='256k', case='sparse', public_failure='Sorting/sort_remaining',
                                            value=5*(262144+1), limit=1, fresh_public_call=True), 'missing rejection/recovery proof')
    return report


def verify_fixed_records(report):
    policies = json.loads((ROOT/'testdata/generation/scale-policies.json').read_text(encoding='utf8'))
    require(policies == dict(schema_version=1, status='0.3.0 Unreleased; explicit source policies, defaults unchanged',
                             stages={s: dict(size_bytes=n, limits=policy(n),
                                             application_limits={**policy(n), 'max_sort_work': 1, 'max_match_work': 1})
                                     for s, n in SIZES.items()}), 'fixed policy manifest differs')
    cli = json.loads((ROOT/'testdata/generation/scale-cli.json').read_text(encoding='utf8'))
    require(len(cli) == 2, 'missing/extra CLI evidence')
    for row, stage in zip(cli, SIZES):
        limits = policy(SIZES[stage])
        measured = next(r for r in report['measurements'] if r['id'] == stage+'-random')
        require(row['stage'] == stage and row['case'] == 'random' and row['limits'] == limits and
                row['application_limits'] == {**limits, 'max_sort_work': 1, 'max_match_work': 1}, 'CLI identity/configuration differs')
        require(row['commands'] == [
            ['diff', *cli_flags(limits, 'diff'), 'old.bin', 'new.bin', 'update.patch'],
            ['patch', *cli_flags(limits, 'patch'), 'old.bin', 'update.patch', 'restored.bin']], 'CLI replay command differs')
        require(row['byte_equal'] is True and all(row[k] == measured[k] for k in
                ('old_sha256', 'new_sha256', 'restored_sha256', 'patch_bytes', 'patch_sha256')) and
                re.fullmatch('[0-9a-f]{64}', row['executable_sha256']), 'CLI byte/hash evidence differs')


def measure(stage, output, prior):
    require(platform.system() == 'Linux', 'measurement target is Linux native release')
    require(not output.exists(), 'refusing to replace evidence output')
    if stage == '1m':
        require(prior is not None, 'complete 256 KiB stage first')
        previous = verify(json.loads(prior.read_text(encoding='utf8')), current=True)
        require(previous['stages'] == ['256k'], 'prior must be the completed first stage')
    else:
        require(prior is None, 'first stage cannot have prior results')
        previous = None
    toolchain = subprocess.check_output(['moon', 'version', '--all'], text=True)
    require('moon 0.1.20261102 (ea07287 2026-11-02)' in toolchain and 'moonc v0.10.19+bee578715' in toolchain, 'wrong SDK')
    folder = ROOT/'_build/generation-scales'/('run-'+uuid.uuid4().hex)
    folder.mkdir(parents=True)
    n = SIZES[stage]
    limits = policy(n)
    write(folder/'plan.json', dict(stage=stage, kinds=KINDS, limits=limits, warmups=0, repeats=1, timeout_seconds=180))
    source_hashes = identities()
    rows = []
    with tempfile.TemporaryDirectory(prefix='moonbsdiff-scale-source-') as temp:
        snapshot = pathlib.Path(temp)
        for p in production()+[ROOT/'moon.mod', ROOT/'moon.pkg']:
            shutil.copyfile(p, snapshot/p.name)
        shutil.copytree(ROOT/'internal', snapshot/'internal')
        os.symlink(ROOT/'.mooncakes', snapshot/'.mooncakes', target_is_directory=True)
        for name, digest in source_hashes.items():
            require(sha((snapshot/name).read_bytes()) == digest, 'snapshot production bytes differ: '+name)
        with (snapshot/'moon.pkg').open('a', encoding='utf8') as f:
            f.write('\nimport { "moonbitlang/core/bench", "moonbitstack/mooncrypt/hash/sha2" } for "wbtest"\n')
        text = (ROOT/'scripts/generation_scale.mbt.in').read_text(encoding='utf8')
        tests = []
        config = '{ '+', '.join(k+': '+str(v)+'L' for k, v in limits.items())+' }'
        for index, kind in enumerate(KINDS):
            tests.append('///|\ntest "scale-'+kind+'" { scale_case('+str(n)+', '+str(index)+', '+config+', '+str(stage=='256k' and index==0).lower()+') }')
        bridge = snapshot/'scale_wbtest.mbt'
        bridge.write_text(text.replace('@TESTS@', '\n'.join(tests)), encoding='utf8')
        base = ['moon', 'test', bridge.name, '--target', 'native', '--release', '--deny-warn']
        built = subprocess.run(base+['--build-only'], cwd=snapshot, capture_output=True, timeout=180)
        (folder/'build.log').write_bytes(built.stdout+built.stderr)
        require(built.returncode == 0, 'snapshot build failed; '+str(folder/'build.log'))
        for kind in KINDS:
            rss = folder/(kind+'-rss.json')
            command = ['/usr/bin/time', '-f', '{"max_rss_kib":%M}', '-o', str(rss), *base, '--filter', 'scale-'+kind]
            start = time.perf_counter()
            result = subprocess.run(command, cwd=snapshot, capture_output=True, timeout=180)
            elapsed = time.perf_counter()-start
            (folder/(kind+'.stdout')).write_bytes(result.stdout)
            (folder/(kind+'.stderr')).write_bytes(result.stderr)
            require(result.returncode == 0, 'bounded scale run failed: '+stage+'-'+kind+'; '+str(folder))
            lines = result.stdout.decode().splitlines()
            require(lines[-1:] == ['Total tests: 1, passed: 1, failed: 0.'] and
                    len([s for s in lines if s.startswith('SCALE:')]) == 1, 'missing/duplicate/nonempty test result')
            probe = stage == '256k' and kind == 'sparse'
            require(lines.count('SCALE-PROBE:rejected-sorting-and-fresh-public-call-passed') == int(probe) and
                    len(lines) == 2+int(probe), 'extra output or missing rejection/recovery proof')
            parts = next(s for s in lines if s.startswith('SCALE:')).split(':')[1:]
            require(len(parts) == 12, 'invalid measurement protocol')
            sort, work, patch, gus, aus, ctl, diff, extra, oh, nh, rh, ph = parts
            sort, work, patch, ctl, diff, extra = map(int, (sort, work, patch, ctl, diff, extra))
            feeds = sum((b+32767)//32768 for b in (ctl, diff, extra))+3
            encoding = 4*(ctl+diff+extra)+2*(ctl//24)
            wrapper = feeds+2*(patch-32)
            assembly = 3*patch
            row = dict(id=stage+'-'+kind, old_size=n, new_size=n, old_sha256=oh, new_sha256=nh,
                       restored_sha256=rh, patch_sha256=ph, byte_equal=True, inputs_unchanged=True,
                       limits=limits, sort_work=sort, sort_initialization_work=5*(n+1),
                       sort_round_work=sort-5*(n+1), match_work=work,
                       match_work_breakdown=dict(scan=work-encoding-wrapper-assembly,
                                                 raw_validation_encoding=encoding,
                                                 compression_wrapper=wrapper, final_assembly=assembly),
                       raw_control_bytes=ctl, raw_diff_bytes=diff, raw_extra_bytes=extra,
                       raw_total_bytes=ctl+diff+extra, control_count=ctl//24, patch_bytes=patch,
                       generate_seconds=float(gus)/1000000, apply_seconds=float(aus)/1000000,
                       process_seconds=elapsed, invocation_max_rss_kib=json.loads(rss.read_text())['max_rss_kib'])
            rows.append(row)
            print('SCALE RESULT '+json.dumps(row), flush=True)
    report = dict(schema_version=1, recipe='LCG32-v1 high byte, seeds 2026112301+n and 2026112303+n; sparse XOR85 at n/7,n/3,n/2,n-1; period7 rotated by3',
                  baseline_sha=subprocess.check_output(['git', '-c', 'safe.directory='+ROOT.as_posix(), 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  sources=source_hashes, stages=(previous['stages'] if previous else [])+[stage],
                  platform=platform.platform(), architecture=platform.machine(),
                  cpu=next(line.split(':', 1)[1].strip() for line in pathlib.Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name')),
                  toolchain=[line[:line.index(')')+1] for line in toolchain.splitlines() if re.match(r'^(moon |moonc |moonrun )', line)],
                  compiler=subprocess.check_output(['cc', '--version'], text=True).splitlines()[0],
                  mode='native release; byte-identical production snapshot; wbtest-only clock/hash imports', warmups=0, repeats=1,
                  timing='core monotonic microseconds around one generate_patch (actual diff body) and one public apply, excluding input/hash/assertion/diagnostics; process perf_counter includes moon runner/startup/input construction/diagnostics and one small failure/recovery probe in first case; build excluded',
                  accounting='total budgets observed directly; phase components derived from actual block lengths and unchanged declared reservation formulas, scan is the remainder',
                  memory=dict(invocation_max_rss='GNU time %M kernel maximum RSS for moon test invocation including runner/child and diagnostics; not simultaneous subtree sum or API-only peak', sampled_rss='not measured', api_peak='not measured'),
                  low_quota_probe=dict(stage='256k', case='sparse', public_failure='Sorting/sort_remaining', value=5*(262144+1), limit=1, fresh_public_call=True),
                  measurements=(previous['measurements'] if previous else [])+rows)
    verify(report, current=True)
    write(output, report)
    print('SCALE REPORT '+str(output), flush=True)


def cli_flags(limits, operation):
    fields = [('max_old_bytes', '--max-old-bytes'), ('max_new_bytes', '--max-new-bytes'),
              ('max_output_bytes', '--max-output-bytes'), ('max_patch_bytes', '--max-patch-bytes'),
              ('max_decompressed_bytes', '--max-expanded-bytes'), ('max_control_instructions', '--max-controls')]
    if operation == 'diff':
        fields += [('max_sort_work', '--max-sort-work'), ('max_match_work', '--max-match-work')]
    return [word for key, option in fields for word in (option, str(limits[key]))]


def replay(exe, stage, kind):
    exe = exe.resolve()
    require(exe.is_file(), 'CLI executable missing')
    limits = policy(SIZES[stage])
    old, new = inputs(SIZES[stage], kind)
    commands = []
    with tempfile.TemporaryDirectory(prefix='moonbsdiff-scale-cli-') as temp:
        work = pathlib.Path(temp)
        (work/'old.bin').write_bytes(old)
        (work/'new.bin').write_bytes(new)
        for operation, operands in [('diff', ['old.bin', 'new.bin', 'update.patch']), ('patch', ['old.bin', 'update.patch', 'restored.bin'])]:
            args = [str(exe), operation, *cli_flags(limits, operation), *operands]
            r = subprocess.run(args, cwd=work, capture_output=True, timeout=180)
            require(r.returncode == 0 and not r.stdout and not r.stderr, 'CLI replay failed: '+r.stderr.decode(errors='replace'))
            commands.append(args[1:])
        require((work/'restored.bin').read_bytes() == new, 'CLI full-byte restoration differs')
        require((work/'old.bin').read_bytes() == old and (work/'new.bin').read_bytes() == new, 'CLI input changed')
        row = dict(stage=stage, case=kind, limits=limits, commands=commands, byte_equal=True,
                   application_limits={**limits, 'max_sort_work': 1, 'max_match_work': 1},
                   old_sha256=sha(old), new_sha256=sha(new), restored_sha256=sha((work/'restored.bin').read_bytes()),
                   patch_bytes=(work/'update.patch').stat().st_size, patch_sha256=sha((work/'update.patch').read_bytes()),
                   executable_sha256=sha(exe.read_bytes()))
    path = ROOT/'_build/generation-scales'/('cli-'+uuid.uuid4().hex+'.json')
    write(path, row)
    print('SCALE CLI '+json.dumps(row))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--measure-stage', choices=SIZES)
    p.add_argument('--output', type=pathlib.Path)
    p.add_argument('--prior', type=pathlib.Path)
    p.add_argument('--verify-report', type=pathlib.Path, nargs='?', const=RECORD)
    p.add_argument('--replay-cli', type=pathlib.Path)
    p.add_argument('--stage', choices=SIZES)
    p.add_argument('--case', choices=KINDS, default='random')
    a = p.parse_args()
    if a.measure_stage:
        require(a.output is not None, '--output required')
        measure(a.measure_stage, a.output, a.prior)
    elif a.verify_report:
        report = verify(json.loads(a.verify_report.read_text(encoding='utf8')), current=True)
        if a.verify_report.resolve() == RECORD.resolve():
            verify_fixed_records(report)
        print('Scale identities, policies, work, raw blocks and restoration evidence: PASS')
    elif a.replay_cli:
        require(a.stage is not None, '--stage required')
        replay(a.replay_cli, a.stage, a.case)
    else:
        p.error('choose --measure-stage, --verify-report or --replay-cli')
