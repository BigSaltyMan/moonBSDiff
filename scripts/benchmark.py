"""Five fixed small native-release process benchmarks, never a push-time timing job."""
import argparse,json,math,pathlib,platform,re,statistics,subprocess,sys,tempfile,time,uuid
if not __debug__:raise RuntimeError("Benchmark checks require Python without -O")
from conformance_cases import lcg,sha
from oracle_identity import verified_tools
ROOT=pathlib.Path(__file__).resolve().parents[1]
REPORT=ROOT/'testdata/benchmarks/results.json'
IDS=['same-4096','sparse-4096','periodic-4096','random-4096','wasm-update']

def synthetic():
    n=4096;old=lcg(2026110801+n,n);edit=bytearray(old)
    for pos in (n//7,n//3,n//2,n-1):edit[pos]^=85
    return [('same-4096',old,old),('sparse-4096',old,bytes(edit)),('periodic-4096',bytes(i%7 for i in range(n)),bytes((i+3)%7 for i in range(n))),('random-4096',old,lcg(2026110803+n,n))]

def identity(cid,old,new):return dict(id=cid,old_size=len(old),new_size=len(new),old_sha256=sha(old),new_sha256=sha(new))
def verify():
    r=json.loads(REPORT.read_text())
    assert r['oracle']==json.loads((ROOT/'tools/oracle/verified-build.json').read_text())
    assert 'moonc v0.10.19+bee578715' in r['toolchain']
    assert re.fullmatch('[0-9a-f]{40}',r['library_source_sha'])
    assert r['case_ids']==IDS and r['warmups']==1 and r['repeats']==3
    expected=[identity(*s) for s in synthetic()]
    m=json.loads((ROOT/'examples/wasm-update/manifest.json').read_text())
    expected.append(dict(id='wasm-update',old_size=m['expected']['v1']['size'],new_size=m['expected']['v2']['size'],old_sha256=m['expected']['v1']['sha256'],new_sha256=m['expected']['v2']['sha256']))
    assert [x['input'] for x in r['cases']]==expected
    for row in r['cases']:
        assert set(row['implementations'])=={'moon','upstream'}
        for impl in row['implementations'].values():
            assert impl['restored_sha256']==row['input']['new_sha256'] and impl['byte_equal'] is True
            for op in ['generate','apply']:
                samples=impl[op+'_seconds'];assert len(samples)==3 and all(type(v) in (int,float) and math.isfinite(v) and v>0 for v in samples)
                assert impl[op+'_median_seconds']==statistics.median(samples)
            assert type(impl['patch_size']) is int and impl['patch_size']>0 and re.fullmatch('[0-9a-f]{64}',impl['patch_sha256'])
    print('Five fixed benchmark identities, three raw samples per operation and medians verified; timings are historical')

def run(command,cwd):
    start=time.perf_counter();r=subprocess.run(list(map(str,command)),cwd=cwd,capture_output=True,timeout=30);elapsed=time.perf_counter()-start
    if r.returncode:raise RuntimeError(str(command)+' failed: '+r.stderr.decode('utf8',errors='replace'))
    return elapsed

def main():
    if platform.system()!='Linux':raise RuntimeError('Use Linux/WSL so both implementations run in the same environment')
    tools,oracle=verified_tools()
    source_sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    version=subprocess.check_output(['moon','version','--all'],text=True)
    assert 'moon 0.1.20261102 (ea07287 2026-11-02)' in version and 'moonc v0.10.19+bee578715' in version
    folder=ROOT/'_build/benchmarks'/('run-'+uuid.uuid4().hex);folder.mkdir(parents=True)
    # Plan is fixed before builds/timing. No tuning/reselection after results.
    plan=dict(case_ids=IDS,warmups=1,repeats=3,scales=[4096,3962],method='subprocess elapsed perf_counter, startup + CLI file IO + operation + close/delivery; excludes compile and Python full-byte/hash comparison; core API latency not measured')
    (folder/'plan.json').write_text(json.dumps(plan,indent=2)+'\n')
    subprocess.run([sys.executable,'scripts/build_cli.py','--release'],cwd=ROOT,check=True,timeout=180)
    cli=ROOT/'_build/bin/linux/moonbsdiff'
    subprocess.run(['moon','build','examples/wasm-update/v1','examples/wasm-update/v2','--target','wasm-gc','--release','--strip','--target-dir',str(folder/'modules')],cwd=ROOT,check=True,timeout=180)
    manifest=json.loads((ROOT/'examples/wasm-update/manifest.json').read_text())
    wasm=[]
    for v in ['v1','v2']:
        raw=(folder/'modules/wasm-gc/release/build/examples/wasm-update'/v/(v+'.wasm')).read_bytes()
        assert dict(size=len(raw),sha256=sha(raw))==manifest['expected'][v];wasm.append(raw)
    cases=synthetic()+[('wasm-update',*wasm)];records=[]
    work_root=pathlib.Path(tempfile.mkdtemp(prefix='moonbsdiff-benchmark-'))
    for cid,old,new in cases:
        work=work_root/cid;work.mkdir();a=work/'old';b=work/'new';a.write_bytes(old);b.write_bytes(new)
        record=dict(input=identity(cid,old,new),implementations={})
        for name in ['moon','upstream']:
            times={'generate':[],'apply':[]};last=None
            for repeat in range(4):
                patch=work/(name+'-'+str(repeat)+'.patch');out=work/(name+'-'+str(repeat)+'.restored')
                assert not patch.exists() and not out.exists()
                diff=[cli,'diff',a,b,patch] if name=='moon' else [tools['bsdiff'],a,b,patch]
                apply=[cli,'patch',a,patch,out] if name=='moon' else [tools['bspatch'],a,out,patch]
                dt=run(diff,work);assert patch.is_file();at=run(apply,work);assert out.is_file() and out.read_bytes()==new
                assert a.read_bytes()==old and b.read_bytes()==new
                if repeat:times['generate'].append(dt);times['apply'].append(at)
                last=dict(patch_size=patch.stat().st_size,patch_sha256=sha(patch.read_bytes()),restored_sha256=sha(out.read_bytes()),byte_equal=True)
            record['implementations'][name]=dict(last,generate_seconds=times['generate'],apply_seconds=times['apply'],generate_median_seconds=statistics.median(times['generate']),apply_median_seconds=statistics.median(times['apply']))
        records.append(record)
    cpu=next(line.split(':',1)[1].strip() for line in pathlib.Path('/proc/cpuinfo').read_text().splitlines() if line.startswith('model name'))
    report=dict(plan,platform=platform.platform(),architecture=platform.machine(),cpu=cpu,library_source_sha=source_sha,toolchain='\n'.join(line.split(' /')[0] for line in version.splitlines() if not line.startswith('feature flags:')),python=platform.python_version(),mode='native release, scripts/build_cli.py --release, default compiler flags',compiler=subprocess.check_output(['gcc','--version'],text=True).splitlines()[0],cli_sha256=sha(cli.read_bytes()),oracle=oracle,limits=dict(diff='Limits::for_diff()',patch='Limits::for_apply(), only max_patch_bytes=131072',old_new_output_bytes=65536,patch_bytes=131072,raw_bytes=262144,instructions=4096,sort_work=8388608,match_work=8388608),output_filesystem='/tmp on WSL Linux filesystem, same paths for both tools; not Windows-mounted DrvFS',peak_memory='not measured',sampled_rss='not measured',core_api_time='not measured',cases=records)
    (folder/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print('BENCHMARK RESULTS '+str(folder/'results.json'))
    for r in records:
        print(r['input']['id'],[(n,round(v['generate_median_seconds']*1000,3),round(v['apply_median_seconds']*1000,3),v['patch_size']) for n,v in r['implementations'].items()])
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--verify',action='store_true');a=p.parse_args()
    if a.verify:verify()
    else:main()
