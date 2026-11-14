"""Run only the two Commit 14 examples, using fixed independently compiled expectations."""
import argparse,hashlib,json,pathlib,platform,subprocess,sys,uuid
from build_cli import version as module_version
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(raw):return hashlib.sha256(raw).hexdigest()
def require(ok,what):
    if not ok:raise RuntimeError(what)
def command(args,cwd):
    print('COMMAND '+json.dumps(list(map(str,args))),flush=True)
    subprocess.run(list(map(str,args)),cwd=cwd,check=True,timeout=180)
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--cli',type=pathlib.Path);a=parser.parse_args()
    manifest=json.loads((ROOT/'examples/wasm-update/manifest.json').read_text(encoding='utf8'))
    version=subprocess.check_output(['moon','version','--all'],text=True)
    expected=manifest['expected_by_module_version'][module_version()]
    require(all(line in version for line in manifest['toolchain']),'wrong toolchain')
    for name,digest in manifest['source_sha256'].items():require(sha((ROOT/name).read_bytes())==digest,'source differs: '+name)
    run=ROOT/'_build/examples'/('run-'+uuid.uuid4().hex);run.mkdir(parents=True,exist_ok=False)
    command(['moon','run','cmd/example','--target','js','--target-dir',run/'basic'],ROOT)
    artifacts={}
    for v in ['v1','v2']:
        command(['moon','build','examples/wasm-update/'+v,'--target','wasm-gc','--release','--strip','--deny-warn','--target-dir',run/'modules'],ROOT)
        path=run/'modules/wasm-gc/release/build/examples/wasm-update'/v/(v+'.wasm')
        raw=path.read_bytes();require(raw[:8]==b'\0asm\1\0\0\0','not a Wasm module')
        require(dict(size=len(raw),sha256=sha(raw))==expected[v],'compiled bytes differ from fixed '+v+' expectation')
        require(len(raw)<=65536,'module exceeds CLI generation cap');artifacts[v]=path
    if a.cli:cli=a.cli.resolve()
    else:
        command([sys.executable,ROOT/'scripts/build_cli.py'],ROOT)
        cli=ROOT/'_build/bin'/platform.system().lower()/('moonbsdiff.exe' if platform.system()=='Windows' else 'moonbsdiff')
    require(cli.is_file(),'official CLI executable missing')
    patch=run/'update.patch';restored=run/'restored.wasm'
    # The old identity is checked before both operations, not inferred from BSDIFF40.
    require(sha(artifacts['v1'].read_bytes())==expected['v1']['sha256'],'wrong old identity')
    command([cli,'diff',artifacts['v1'],artifacts['v2'],patch],run)
    require(sha(artifacts['v1'].read_bytes())==expected['v1']['sha256'],'old file changed')
    command([cli,'patch',artifacts['v1'],patch,restored],run)
    actual=restored.read_bytes();expected=artifacts['v2'].read_bytes()
    require(actual==expected,'complete byte comparison failed')
    require(sha(actual)==expected['v2']['sha256'],'restored expected hash differs')
    report=dict(toolchain=version,target='wasm-gc',flags=manifest['flags'],sources=manifest['source_sha256'],files={name:dict(size=p.stat().st_size,sha256=sha(p.read_bytes())) for name,p in dict(old=artifacts['v1'],new=artifacts['v2'],patch=patch,restored=restored).items()},byte_equal=True,run_directory=str(run))
    (run/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print('EXAMPLES PASS '+json.dumps(report,sort_keys=True))
if __name__=='__main__':main()
