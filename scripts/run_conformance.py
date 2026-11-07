"""Explicit, bounded two-way BSDiff executor. Default action only verifies inventory."""
import argparse,hashlib,json,pathlib,platform,subprocess,sys,uuid
from conformance_cases import ROOT,MANIFEST,load_manifest,sha
from conformance_protocol import ConformanceError,require,compare,run_process,parse_moon_log,validate_rows,read_json
from oracle_identity import verified_tools
from check_diff import parse
from check_apply import literal

BRIDGE=ROOT/'conformance_generated_test.mbt'

def json_write(path,value):
    path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf8',newline='\n')
def source_identity():
    files=[p for p in ROOT.glob('*.mbt') if not p.name.endswith(('_test.mbt','_wbtest.mbt'))]
    files+=list((ROOT/'internal/bzip2').glob('*.mbt'))+[ROOT/'moon.mod',ROOT/'moon.pkg']
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(files)}
def checked_request(directory):
    request=read_json((directory/'request.json').read_text())
    require(request['manifest_sha256']==sha(MANIFEST.read_bytes()),'manifest changed during run')
    require(request['sources']==source_identity(),'library source state changed during run')
    return request
def case_ids(request,manifest,target):
    return [request['case']] if request['case'] else manifest['matrix'][target]
def all_ids(request,manifest):
    selected={cid for target in request['targets'] for cid in case_ids(request,manifest,target)}
    return [row['id'] for row in manifest['cases'] if row['id'] in selected]
def verify_input_files(directory,cid,data):
    for kind in ('old','new'):
        require((directory/'inputs'/cid/(kind+'.bin')).read_bytes()==data[cid][kind],'materialized input identity mismatch: '+cid)

def record(request,row,target,direction,raw,kind='restored'):
    return dict(schema=1,run_id=request['run_id'],manifest_sha256=request['manifest_sha256'],case_id=row['id'],target=target,direction=direction,old_sha256=row['old_sha256'],new_sha256=row['new_sha256'],status='ok',payload_kind=kind,payload_hex=raw.hex())
def with_case(error,cid,target=None,direction=None):
    error.case_id=cid;error.target=target;error.direction=direction
    return error

def prepare(directory):
    manifest,data=load_manifest();request=checked_request(directory);tools,identity=verified_tools(pathlib.Path(request['oracle_record']))
    upstream=json.loads((ROOT/'testdata/upstream/manifest.json').read_text());upstream={r['id']:r for r in upstream['cases']}
    cases={r['id']:r for r in manifest['cases']};results=[]
    for cid in all_ids(request,manifest):
        folder=directory/'inputs'/cid;folder.mkdir(parents=True,exist_ok=False)
        for kind in ('old','new'):(folder/(kind+'.bin')).write_bytes(data[cid][kind])
        patch=folder/'oracle.patch'
        try:
            if cases[cid]['source']['kind']=='upstream':
                ref=upstream[cid]['patch'];raw=(ROOT/'testdata/upstream'/ref['path']).read_bytes()
                require(len(raw)==ref['size'] and sha(raw)==ref['sha256'],'fixed upstream patch identity mismatch')
                patch.write_bytes(raw);origin='fixed Commit 3 patch'
            else:
                run_process([tools['bsdiff'],folder/'old.bin',folder/'new.bin',patch],folder/'bsdiff',output=patch,timeout=15,cwd=ROOT)
                origin='real bsdiff this run'
            parse(patch.read_bytes(),data[cid]['old'],data[cid]['new'])
            results.append(dict(case_id=cid,origin=origin,patch_sha256=sha(patch.read_bytes())))
        except Exception as error:raise with_case(error,cid,direction='oracle-to-moon')
    json_write(directory/'prepared.json',dict(run_id=request['run_id'],manifest_sha256=request['manifest_sha256'],oracle=identity['products'],cases=results))
    print(f'prepared {len(results)} independently verified upstream patches')

def apply_exports(directory):
    manifest,data=load_manifest();request=checked_request(directory);tools,_=verified_tools(pathlib.Path(request['oracle_record']))
    cases={r['id']:r for r in manifest['cases']}
    tasks=read_json((directory/'b-tasks.json').read_text());require(type(tasks) is list,'invalid oracle task list')
    expected={(target,cid) for target in request['targets'] for cid in case_ids(request,manifest,target)}
    actual=set();records=[]
    for task in tasks:
        require(set(task)=={'run_id','target','case_id','patch_sha256'},'unexpected oracle task fields')
        key=(task['target'],task['case_id']);require(key in expected and key not in actual,'extra/duplicate oracle task')
        require(task['run_id']==request['run_id'],'stale oracle task');actual.add(key)
    require(actual==expected,'missing oracle task')
    for task in tasks:
        target,cid=task['target'],task['case_id'];folder=directory/'targets'/target/cid;patch=folder/'moon.patch';output=folder/'oracle-restored.bin'
        try:
            verify_input_files(directory,cid,data)
            require(sha(patch.read_bytes())==task['patch_sha256'],'exported patch changed')
            parse(patch.read_bytes(),data[cid]['old'],data[cid]['new'])
            run_process([tools['bspatch'],directory/'inputs'/cid/'old.bin',output,patch],folder/'bspatch',output=output,timeout=15,cwd=ROOT)
            compare(output.read_bytes(),data[cid]['new'])
            records.append(record(request,cases[cid],target,'moon-to-oracle',output.read_bytes()))
        except Exception as error:raise with_case(error,cid,target,'moon-to-oracle')
    json_write(directory/'oracle-results.json',dict(run_id=request['run_id'],manifest_sha256=request['manifest_sha256'],records=records))
    print(f'upstream bspatch executed and fully compared {len(records)} outputs')

def bridge_source(directory,request,manifest,data,target):
    source=['///|','fn conformance_emit(prefix : String, bytes : Bytes) -> Unit {','  let digits = b"0123456789abcdef"','  let text = StringBuilder()','  for b in bytes { text.write_char(digits[b.to_int()/16].to_int().to_char().unwrap()); text.write_char(digits[b.to_int()%16].to_int().to_char().unwrap()) }','  println("CONFORMANCE:"+prefix+text.to_string()+"\\\"}")','}']
    cases={r['id']:r for r in manifest['cases']}
    for i,cid in enumerate(case_ids(request,manifest,target)):
        values=dict(old=data[cid]['old'],new=data[cid]['new'],patch=(directory/'inputs'/cid/'oracle.patch').read_bytes())
        for kind,raw in values.items():source+=['','///|',f'fn conformance_{i}_{kind}() -> Bytes {{',literal(raw),'}']
        source+=['','///|',f'test "conformance-{cid}" {{','  let limits : @moonbsdiff.Limits = { max_old_bytes: 8192L, max_new_bytes: 8192L, max_patch_bytes: 32768L, max_output_bytes: 8192L, max_decompressed_bytes: 131072L, max_control_instructions: 4096L, max_sort_work: 100000000L, max_match_work: 100000000L }',f'  let old = conformance_{i}_old()',f'  let new = conformance_{i}_new()',f'  let restored = match @moonbsdiff.apply(old,conformance_{i}_patch(),limits) {{ Ok(b) => b; Err(_) => abort("apply failed: {cid}") }}',f'  let patch = match @moonbsdiff.diff(old,new,limits) {{ Ok(b) => b; Err(_) => abort("diff failed: {cid}") }}']
        for direction,kind,value in [('oracle-to-moon','restored','restored'),('moon-to-oracle','patch','patch')]:
            metadata=record(request,cases[cid],target,direction,b'',kind);del metadata['payload_hex']
            prefix=json.dumps(metadata,separators=(',',':'))[:-1]+',"payload_hex":"'
            source+=[f'  conformance_emit({json.dumps(prefix)},{value})']
        source+=['}']
    return '\n'.join(source)+'\n'

def wsl_path(path):
    path=path.resolve();return '/mnt/'+path.drive[0].lower()+path.as_posix()[2:]
def oracle_phase(directory,phase):
    if sys.platform=='win32':args=['wsl','-d','Ubuntu-24.04','--','python3',wsl_path(ROOT/'scripts/run_conformance.py'),'--phase',phase,'--directory',wsl_path(directory)]
    else:args=[sys.executable,str(ROOT/'scripts/run_conformance.py'),'--phase',phase,'--directory',str(directory)]
    run_process(args,directory/('phase-'+phase),output=directory/('prepared.json' if phase=='prepare' else 'oracle-results.json'),timeout=120,cwd=ROOT)

def run(args):
    manifest,data=load_manifest();require(len(set(args.targets))==len(args.targets),'duplicate requested target')
    ids={r['id'] for r in manifest['cases']};require(not args.case or args.case in ids,'unknown replay case')
    require(not BRIDGE.exists(),'refusing to overwrite existing bridge file')
    directory=ROOT/'_build/conformance'/('run-'+uuid.uuid4().hex);directory.mkdir(parents=True,exist_ok=False)
    request=dict(schema=1,run_id=directory.name[4:],manifest_sha256=sha(MANIFEST.read_bytes()),targets=args.targets,case=args.case,sources=source_identity(),oracle_record=args.oracle_record.as_posix(),scope='full' if not args.case and args.targets==['native','js','wasm-gc'] else 'subset/replay')
    if sys.platform=='win32':request['oracle_record']=wsl_path(args.oracle_record)
    json_write(directory/'request.json',request)
    print('run directory:',directory,flush=True)
    try:
        version=run_process(['moon','version','--all'],directory/'toolchain',cwd=ROOT).stdout.decode('utf8')
        require('moon 0.1.20261102 (ea07287 2026-11-02)' in version and 'moonc v0.10.19+bee578715 (2026-11-02)' in version,'wrong isolated toolchain')
        oracle_phase(directory,'prepare')
        prepared=read_json((directory/'prepared.json').read_text());require(prepared['run_id']==request['run_id'] and prepared['manifest_sha256']==request['manifest_sha256'],'stale prepared metadata')
        require([r['case_id'] for r in prepared['cases']]==all_ids(request,manifest),'prepared case set mismatch')
        cases={r['id']:r for r in manifest['cases']};tasks=[];final_records=[]
        oracle_hashes={r['case_id']:r['patch_sha256'] for r in prepared['cases']}
        for target in args.targets:
            checked_request(directory)
            for cid in case_ids(request,manifest,target):
                verify_input_files(directory,cid,data)
                require(sha((directory/'inputs'/cid/'oracle.patch').read_bytes())==oracle_hashes[cid],'prepared oracle patch changed')
            text=bridge_source(directory,request,manifest,data,target);BRIDGE.write_text(text,encoding='utf8',newline='\n')
            target_dir=directory/'targets'/target;target_dir.mkdir(parents=True)
            (target_dir/'bridge.mbt').write_text(text,encoding='utf8',newline='\n')
            command=['moon','test',BRIDGE.name,'--target',target,'--deny-warn']
            run_process(command+['--build-only'],target_dir/'build',timeout=120,cwd=ROOT)
            result=run_process(command,target_dir/'execute',timeout=120,cwd=ROOT)
            selected=case_ids(request,manifest,target)
            rows=parse_moon_log(result.stdout.decode('utf8'),request,target,selected,cases)
            for cid in selected:
                folder=target_dir/cid;folder.mkdir()
                try:
                    restored=rows[(cid,'oracle-to-moon')];(folder/'moon-restored.bin').write_bytes(restored)
                    compare(restored,data[cid]['new'])
                    patch=rows[(cid,'moon-to-oracle')];(folder/'moon.patch').write_bytes(patch)
                    parse(patch,data[cid]['old'],data[cid]['new'])
                    final_records.append(record(request,cases[cid],target,'oracle-to-moon',restored))
                    tasks.append(dict(run_id=request['run_id'],target=target,case_id=cid,patch_sha256=sha(patch)))
                except Exception as error:raise with_case(error,cid,target)
            BRIDGE.unlink()
        json_write(directory/'b-tasks.json',tasks)
        oracle_phase(directory,'apply')
        results=read_json((directory/'oracle-results.json').read_text());require(results['run_id']==request['run_id'] and results['manifest_sha256']==request['manifest_sha256'],'stale oracle results')
        require(set(results)=={'run_id','manifest_sha256','records'},'unexpected oracle result envelope')
        require(all(r['target'] in request['targets'] for r in results['records']),'extra oracle target')
        for target in request['targets']:
            selected=case_ids(request,manifest,target)
            records=[r for r in results['records'] if r['target']==target]
            actual=validate_rows(records,request,target,selected,cases,directions=('moon-to-oracle',))
            for cid in selected:compare(actual[(cid,'moon-to-oracle')],data[cid]['new'])
        final_records+=results['records']
        checked_request(directory)
        counts={};identities=[]
        for target in request['targets']:
            selected=case_ids(request,manifest,target)
            actual=validate_rows([r for r in final_records if r['target']==target],request,target,selected,cases)
            for direction in ('oracle-to-moon','moon-to-oracle'):
                for cid in selected:compare(actual[(cid,direction)],data[cid]['new'])
            counts[target]={direction:dict(expected=len(selected),success=len(selected),failed=0,skipped=0) for direction in ('oracle-to-moon','moon-to-oracle')}
            for cid in selected:
                identities.append(dict(target=target,case_id=cid,oracle_patch_sha256=sha((directory/'inputs'/cid/'oracle.patch').read_bytes()),moon_patch_sha256=sha((directory/'targets'/target/cid/'moon.patch').read_bytes()),restored_sha256=sha(data[cid]['new'])))
        json_write(directory/'results.json',dict(run_id=request['run_id'],manifest_sha256=request['manifest_sha256'],records=final_records))
        summary=dict(schema=1,run_id=request['run_id'],scope=request['scope'],manifest_sha256=request['manifest_sha256'],library_sources=request['sources'],toolchain=version,oracle=prepared['oracle'],independent_inputs=len(all_ids(request,manifest)),new_oracle_patches=sum(r['origin']=='real bsdiff this run' for r in prepared['cases']),counts=counts,identities=identities,full_results_sha256=sha((directory/'results.json').read_bytes()))
        json_write(directory/'summary.json',summary)
        print(json.dumps(dict(scope=summary['scope'],independent_inputs=summary['independent_inputs'],counts=counts),indent=2))
        return directory
    except Exception as error:
        json_write(directory/'failure.json',dict(kind=getattr(error,'kind','environment-or-tool'),message=str(error),case_id=getattr(error,'case_id',None),target=getattr(error,'target',None),direction=getattr(error,'direction',None),request=request))
        raise
    finally:
        BRIDGE.unlink(missing_ok=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--run',action='store_true');parser.add_argument('--targets',nargs='+',choices=['native','js','wasm-gc'],default=['native','js','wasm-gc']);parser.add_argument('--case');parser.add_argument('--phase',choices=['prepare','apply']);parser.add_argument('--directory',type=pathlib.Path);parser.add_argument('--oracle-record',type=pathlib.Path,default=ROOT/'tools/oracle/verified-build.json');args=parser.parse_args()
    if args.phase:
        try:
            if args.phase=='prepare':prepare(args.directory)
            else:apply_exports(args.directory)
        except Exception as error:
            json_write(args.directory/'phase-failure.json',dict(kind=getattr(error,'kind','environment-or-tool'),message=str(error),case_id=getattr(error,'case_id',None),target=getattr(error,'target',None),direction=getattr(error,'direction',None)))
            raise
    elif args.run:run(args)
    else:
        manifest,_=load_manifest();print('inventory verified:',len(manifest['cases']),'inputs; matrix:',{t:len(v) for t,v in manifest['matrix'].items()})
