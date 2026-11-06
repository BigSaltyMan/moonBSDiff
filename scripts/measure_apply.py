"""Native-only bounded measurement; generated package is temporary and ignored."""
import bz2, hashlib, json, pathlib, platform, random, subprocess, time
from check_apply import integer, literal
ROOT=pathlib.Path(__file__).resolve().parents[1]

def samples():
    rows=[]
    for n in (4096,1048576):
        pattern=bytes(i%251 for i in range(n))
        rows += [(f'diff-{n}',pattern,[(n,0,0)],bytes(n),b'',pattern),
                 (f'extra-{n}',b'',[(0,n,0)],b'',pattern,pattern)]
    n=1048576
    rows += [('repeat-1048576',b'',[(0,n,0)],b'',b'A'*n,b'A'*n),
             ('many-controls',bytes(n),[(64,0,0)]*16384,bytes(n),b'',bytes(n)),
             ('zero-controls',b'',[(0,0,0)]*4096+[(0,4096,0)],b'',b'Z'*4096,b'Z'*4096)]
    raw=random.Random(20261106).randbytes(32768)
    rows += [('random-extra-32768',b'',[(0,len(raw),0)],b'',raw,raw)]
    return rows

def main():
    import psutil
    if platform.system() != 'Windows': raise RuntimeError('This measurement recipe is verified on Windows native only')
    package=ROOT/'_apply_measure'
    if package.exists(): raise RuntimeError('refusing to replace existing measurement package')
    package.mkdir()
    try:
        (package/'moon.pkg').write_text('import { "BigSaltyMan/moonbsdiff" }\npkgtype(kind: "executable")\n')
        source=['///|','fn main {','  let limits = @moonbsdiff.Limits::for_apply()']
        records=[]
        for index,(name,old,controls,diff,extra,new) in enumerate(samples()):
            control=b''.join(integer(v) for t in controls for v in t)
            blocks=[bz2.compress(b,compresslevel=9) for b in (control,diff,extra)]
            patch=b'BSDIFF40'+integer(len(blocks[0]))+integer(len(blocks[1]))+integer(len(new))+b''.join(blocks)
            def form(data):
                if not data:return 'b""'
                if len(data)>32768:
                    return f'Bytes::from_array(Array::makei({len(data)}, i => '+ ('(i % 251).to_byte()' if name.startswith(('diff','extra')) else ('b\'A\'' if name.startswith('repeat') else '(0).to_byte()')) + '))'
                return literal(data).strip()
            source += [f'  let old_{index} = '+form(old),f'  let patch_{index} = '+literal(patch).strip(), f'  let expected_{index} = '+form(new),f'  let restored_{index} = match @moonbsdiff.apply(old_{index}, patch_{index}, limits) {{ Err(_) => abort("apply measurement failed: {name}"); Ok(b) => b }}', f'  try! assert_eq(restored_{index}, expected_{index})',f'  println("PASS:{name}")']
            records.append(dict(id=name,old_size=len(old),new_size=len(new),patch_size=len(patch),instructions=len(controls),decoded_bytes=len(control)+len(diff)+len(extra),old_sha256=hashlib.sha256(old).hexdigest(),new_sha256=hashlib.sha256(new).hexdigest(),patch_sha256=hashlib.sha256(patch).hexdigest()))
        source+=['}']
        (package/'main.mbt').write_text('\n'.join(source)+'\n',encoding='utf8')
        subprocess.run(['moon','build','--target','native','--release'],cwd=ROOT,check=True,timeout=120,capture_output=True)
        exe=ROOT/'_build/native/release/build/_apply_measure/_apply_measure.exe'
        if not exe.exists(): raise RuntimeError('missing native measurement executable: '+str(list((ROOT/'_build/native/release').rglob('*.exe'))))
        runs=[]
        for _ in range(3):
            start=time.perf_counter()
            process=subprocess.Popen([str(exe)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            observed=[]
            proc=psutil.Process(process.pid)
            while process.poll() is None:
                if time.perf_counter()-start > 30:
                    process.kill();process.communicate()
                    raise TimeoutError('native measurement exceeded 30 seconds')
                try: observed.append(proc.memory_info().rss)
                except psutil.NoSuchProcess: pass
                time.sleep(0.001)
            out,err=process.communicate(timeout=5)
            assert process.returncode==0,err
            assert out.decode().splitlines()==['PASS:'+r['id'] for r in records]
            runs.append(dict(process_elapsed_seconds=round(time.perf_counter()-start,6),sampled_max_rss_bytes=max(observed) if observed else None))
        report=dict(platform=platform.platform(),architecture=platform.machine(),toolchain='\n'.join(line.split(' ~')[0] for line in subprocess.check_output(['moon','version','--all'],text=True).splitlines() if line and not line.startswith('Feature flags')),executable_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),compiler=(subprocess.run(['cl'],capture_output=True).stderr.decode('utf8',errors='replace').splitlines()[0]),mode='moon build --target native --release; default compiler flags; separate direct executable runs',measurement='whole process: startup + input construction + apply + full byte assertions; RSS sampled at 1ms, not reliable peak memory',peak_memory='not measured',samples=records,runs=runs)
        output=ROOT/'_build/apply-measure.json';output.write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
        print(json.dumps(report,indent=2))
    finally:
        for name in ('main.mbt','moon.pkg'):
            (package/name).unlink(missing_ok=True)
        package.rmdir()

def verify_report():
    report=json.loads((ROOT/'testdata/apply/resource-measurements.json').read_text())
    expected=[]
    for name,old,controls,diff,extra,new in samples():
        control=b''.join(integer(v) for t in controls for v in t)
        blocks=[bz2.compress(b,compresslevel=9) for b in (control,diff,extra)]
        patch=b'BSDIFF40'+integer(len(blocks[0]))+integer(len(blocks[1]))+integer(len(new))+b''.join(blocks)
        expected.append(dict(id=name,old_size=len(old),new_size=len(new),patch_size=len(patch),instructions=len(controls),decoded_bytes=len(control)+len(diff)+len(extra),old_sha256=hashlib.sha256(old).hexdigest(),new_sha256=hashlib.sha256(new).hexdigest(),patch_sha256=hashlib.sha256(patch).hexdigest()))
    assert report['samples']==expected
    assert len(report['runs'])==3 and report['peak_memory']=='not measured'
    assert all(row['process_elapsed_seconds']>0 and row['sampled_max_rss_bytes']>0 for row in report['runs'])
    print('8 measurement input recipes/hashes and saved result structure verified; timings are historical measurements')
if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--verify-report',action='store_true');args=parser.parse_args()
    if args.verify_report:verify_report()
    else:main()
