"""Commit 13 gates: nonempty tests and source-bound existing reference results."""
import argparse,json,os,pathlib,re,subprocess,sys
from conformance_cases import ROOT,MANIFEST,load_manifest,sha
from conformance_protocol import require,run_process,validate_rows,compare,read_json
from run_conformance import source_identity

def test_summary(text):
    rows=re.findall(r'^Total tests: (\d+), passed: (\d+), failed: (\d+)\.\s*$',text,re.M)
    require(bool(rows),'missing test summary')
    require(all(int(n)>0 and n==p and int(f)==0 for n,p,f in rows),'zero/failed tests')
    return sum(int(n) for n,_,_ in rows)

def verify(directory,source_sha,expected_run_id):
    s=read_json((directory/'summary.json').read_text())
    require(s['run_id']==expected_run_id,'stale reference run')
    require(current_sha()==source_sha,'wrong source commit')
    manifest,data=load_manifest()
    request=read_json((directory/'request.json').read_text());result=read_json((directory/'results.json').read_text())
    require(s['scope']=='full' and s['independent_inputs']==31,'incomplete reference scope')
    require(s['library_sources']==source_identity(),'stale library sources')
    require(s['manifest_sha256']==sha(MANIFEST.read_bytes()),'wrong manifest')
    require(result['run_id']==s['run_id']==request['run_id'],'stale run identity')
    require(result['manifest_sha256']==s['manifest_sha256'],'wrong result manifest')
    require(sha((directory/'results.json').read_bytes())==s['full_results_sha256'],'changed results')
    cases={r['id']:r for r in manifest['cases']}
    require(set(s['counts'])==set(manifest['matrix']),'missing/extra targets')
    require(all(r['target'] in manifest['matrix'] for r in result['records']),'extra result target')
    for target,ids in manifest['matrix'].items():
        rows=validate_rows([r for r in result['records'] if r['target']==target],request,target,ids,cases)
        for (cid,direction),raw in rows.items():compare(raw,data[cid]['new'])
        require(s['counts'][target]=={d:dict(expected=len(ids),success=len(ids),failed=0,skipped=0) for d in ['oracle-to-moon','moon-to-oracle']},'incorrect counts')
    provenance=dict(source_sha=source_sha,workflow_sha=os.environ.get('CI_WORKFLOW_SHA'),event=os.environ.get('GITHUB_EVENT_NAME'),run_id=os.environ.get('GITHUB_RUN_ID'),attempt=os.environ.get('GITHUB_RUN_ATTEMPT'))
    return dict(provenance=provenance,reference=s)

def current_sha():
    value=subprocess.check_output(['git','-c','safe.directory='+ROOT.as_posix(),'rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    require(not os.environ.get('GITHUB_SHA') or value==os.environ['GITHUB_SHA'],'checkout does not match CI SHA')
    return value

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--reference',action='store_true');p.add_argument('--test-log',type=pathlib.Path);p.add_argument('command',nargs=argparse.REMAINDER);a=p.parse_args()
    if a.test_log:
        command=a.command[1:] if a.command[:1]==['--'] else a.command
        require(bool(command),'missing test command')
        result=run_process(command,a.test_log,timeout=180,cwd=ROOT)
        text=result.stdout.decode('utf8');print(text,end='');test_summary(text)
        a.test_log.write_bytes(result.stdout)
    elif a.reference:
        source=current_sha()
        before=set((ROOT/'_build/conformance').glob('run-*'))
        run_process([sys.executable,str(ROOT/'tools/oracle/build.py')],ROOT/'_build/reference-build',timeout=300,cwd=ROOT)
        import run_conformance
        directory=run_conformance.run(argparse.Namespace(targets=['native','js','wasm-gc'],case=None,oracle_record=ROOT/'_build/oracle/build.json'))
        require(current_sha()==source,'source commit changed during reference run')
        require(directory not in before,'reference reused old run directory')
        evidence=verify(directory,source,directory.name[4:])
        print('REFERENCE ACCEPTANCE '+json.dumps(evidence,sort_keys=True))
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'],'a',encoding='utf8') as output:output.write('Reference scope: 31 independent inputs; 138 byte-exact restorations. Source `'+source+'`; run `'+evidence['reference']['run_id']+'`.\n')
    else:p.error('choose --reference or --test-log')

if __name__=='__main__':main()
