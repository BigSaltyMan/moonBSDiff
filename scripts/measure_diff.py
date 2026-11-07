"""Bounded native generation measurements; no oracle or performance ranking."""
import argparse,bz2,hashlib,json,pathlib,platform,subprocess,time
from check_apply import literal
from conformance_cases import lcg,sha
from check_diff import parse
from run_conformance import source_identity
ROOT=pathlib.Path(__file__).resolve().parents[1]
BRIDGE=ROOT/'diff_measure_generated_wbtest.mbt'
REPORT=ROOT/'testdata/generation/resource-measurements.json'
ENCODER=ROOT/'testdata/generation/encoder-source.json'

def samples():
    result=[]
    for n in (4096,65536):
        random=lcg(2026110801+n,n)
        sparse=bytearray(random)
        for at in (n//7,n//3,n//2,n-1):sparse[at]^=85
        rows=[('same',random,random),('sparse',random,bytes(sparse)),
          ('insert',random[:-17],random[:n//2]+lcg(2026110802,17)+random[n//2:-17]),
          ('delete',random,random[:n//2]+random[n//2+31:]),
          ('block-move',random,random[n//2:]+random[:n//2]),
          ('repeat',b'A'*n,b'A'*(n-1)+b'B'),
          ('periodic',bytes(i%7 for i in range(n)),bytes((i+3)%7 for i in range(n))),
          ('random',random,lcg(2026110803+n,n))]
        result += [(f'{kind}-{n}',old,new) for kind,old,new in rows]
    return result

def input_records():
    return [dict(id=cid,old_size=len(old),new_size=len(new),old_sha256=sha(old),new_sha256=sha(new)) for cid,old,new in samples()]

def encoder_identity():
    base=ROOT/'.mooncakes/moonbitstack/moonzip/src/bzip2'
    return dict(module='moonbitstack/moonzip',version='0.3.5',license='Apache-2.0',route='public Writer, unchanged installed source',files={name:sha((base/name).read_bytes()) for name in ['stream.mbt','encode.mbt','bwt.mbt','bits.mbt','crc.mbt','decode.mbt','bzip2.mbt']})

def verify():
    report=json.loads(REPORT.read_text());expected=input_records()
    if report['inputs']!=expected:raise ValueError('measurement input recipes/hashes changed')
    if encoder_identity()!=json.loads(ENCODER.read_text()):raise ValueError('fixed encoder source differs')
    if len(report['measurements'])!=len(expected):raise ValueError('missing measurements')
    for row,identity in zip(report['measurements'],expected):
        if row['id']!=identity['id'] or row['sort_work']<=0 or row['match_work']<=0 or row['elapsed_seconds']<=0:raise ValueError('invalid measurement')
    print('16 deterministic generation inputs, historical measurement structure and installed encoder hashes verified')

def verify_stream_log(path):
    lines=path.read_text(encoding='utf8').splitlines()
    values=[line[len('GENSTREAM:'):] for line in lines if line.startswith('GENSTREAM:')]
    if len(values)!=1:raise ValueError('missing/duplicate new Writer boundary stream')
    raw=bytes.fromhex(values[0]);decoder=bz2.BZ2Decompressor();output=decoder.decompress(raw)
    if not decoder.eof or decoder.unused_data or output!=bytes(i%251 for i in range(900010)):raise ValueError('new Writer stream EOF/CRC/content differs')
    print('Writer boundary: independent Python bz2 verified all 900010 original bytes and exact stream end')


def main(candidate=False):
    if BRIDGE.exists():raise RuntimeError('refusing to overwrite existing measurement bridge')
    folder=ROOT/'_build/diff-measure';folder.mkdir(parents=True,exist_ok=True)
    source=[]
    for index,(cid,old,new) in enumerate(samples()):
        for kind,raw in [('old',old),('new',new)]:
            source+=['///|',f'fn diff_measure_{index}_{kind}() -> Bytes {{',literal(raw),'}']
        limits=('{ max_old_bytes: 131072L, max_new_bytes: 131072L, max_patch_bytes: 524288L, max_output_bytes: 131072L, max_decompressed_bytes: 524288L, max_control_instructions: 8192L, max_sort_work: 1000000000L, max_match_work: 1000000000L }' if candidate else 'Limits::for_diff()')
        source+=['///|',f'test "diff-measure-{cid}" {{',f'  let limits : Limits = {limits}',f'  let old = diff_measure_{index}_old()',f'  let new = diff_measure_{index}_new()',
            '  let sort = suffix_test_budget(limits.max_sort_work)','  let work = matching_test_budget(limits.max_match_work)',
            '  let patch = match generate_patch(old,new,limits,sort,work) { Ok(v) => v; Err(_) => abort("generation measurement failed") }',
            '  assert_eq(apply(old,patch,limits), Ok(new))',
            rf'  println("DIFFMEASURE:{cid}:\{{limits.max_sort_work-sort.remaining}}:\{{limits.max_match_work-work.remaining}}:\{{patch.length()}}")',
            '  let digits = b"0123456789abcdef"','  let hex = StringBuilder()',
            '  for b in patch { hex.write_char(digits[b.to_int()/16].to_int().to_char().unwrap()); hex.write_char(digits[b.to_int()%16].to_int().to_char().unwrap()) }',
            '  println("MEASUREPATCH:"+hex.to_string())','}']
    try:
        BRIDGE.write_text('\n'.join(source)+'\n',encoding='utf8',newline='\n')
        base=['moon','test',BRIDGE.name,'--target','native','--release','--deny-warn']
        built=subprocess.run(base+['--build-only'],capture_output=True,timeout=180)
        (folder/'build.log').write_bytes(built.stdout+built.stderr)
        if built.returncode:raise RuntimeError('measurement build failed; see _build/diff-measure/build.log')
        measurements=[]
        for cid,old,new in samples():
            command=base+['--filter','diff-measure-'+cid];start=time.perf_counter()
            run=subprocess.run(command,capture_output=True,timeout=30);elapsed=time.perf_counter()-start
            (folder/(cid+'.stdout.log')).write_bytes(run.stdout);(folder/(cid+'.stderr.log')).write_bytes(run.stderr)
            if run.returncode:raise RuntimeError('measurement failed: '+cid)
            lines=run.stdout.decode('utf8').splitlines()
            if len(lines)!=3 or lines[2]!='Total tests: 1, passed: 1, failed: 0.' or not lines[0].startswith('DIFFMEASURE:'+cid+':') or not lines[1].startswith('MEASUREPATCH:'):raise ValueError('unexpected measurement output: '+cid)
            _,name,sort,match,length=lines[0].split(':');patch=bytes.fromhex(lines[1][13:]);parse(patch,old,new)
            if int(length)!=len(patch):raise ValueError('patch length differs')
            measurements.append(dict(id=cid,sort_work=int(sort),match_work=int(match),patch_size=len(patch),patch_sha256=sha(patch),elapsed_seconds=elapsed,command=command))
        report=dict(schema=1,platform=platform.platform(),architecture=platform.machine(),toolchain=subprocess.check_output(['moon','version','--all'],text=True),mode='native release; default flags; MSVC developer environment',method='one post-build moon test process per case: startup + input construction + one instrumented generation + apply + full output assertion + hex export; Python perf_counter; excludes build and independent Python parse',peak_memory='not measured',sampled_memory='not measured',generator='LCG32 v1; seeds 2026110801+n, 2026110802, 2026110803+n; edits in samples()',configuration='candidate' if candidate else 'Limits::for_diff()',library_sources=source_identity(),inputs=input_records(),measurements=measurements)
        target=folder/('candidate.json' if candidate else 'final.json');target.write_text(json.dumps(report,indent=2)+'\n',encoding='utf8',newline='\n')
        print(json.dumps(dict(report=str(target),cases=len(measurements),max_sort=max(r['sort_work'] for r in measurements),max_match=max(r['match_work'] for r in measurements),max_patch=max(r['patch_size'] for r in measurements),elapsed_total=sum(r['elapsed_seconds'] for r in measurements)),indent=2))
    finally:BRIDGE.unlink(missing_ok=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--verify-report',action='store_true');parser.add_argument('--candidate',action='store_true');parser.add_argument('--stream-log',type=pathlib.Path);args=parser.parse_args()
    if args.verify_report:verify()
    elif args.stream_log:verify_stream_log(args.stream_log)
    else:main(args.candidate)
