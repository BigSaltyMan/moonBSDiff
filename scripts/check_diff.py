"""Check generated diff tests/logs; --oracle additionally runs the fixed bspatch."""
import argparse,bz2,hashlib,json,pathlib,re,subprocess,platform
ROOT=pathlib.Path(__file__).resolve().parents[1]

def sha(raw):return hashlib.sha256(raw).hexdigest()
def inputs():
    manifest=json.loads((ROOT/'testdata/upstream/manifest.json').read_text())
    result={}
    for row in manifest['cases']:
        assert re.fullmatch('[a-z0-9-]+',row['id']) and row['id'] not in result
        data={}
        for kind in ('old','new'):
            data[kind]=(ROOT/'testdata/upstream'/row[kind]['path']).read_bytes()
            assert len(data[kind])==row[kind]['size'] and sha(data[kind])==row[kind]['sha256']
        result[row['id']]=data
    assert len(result)==13
    return result

def tests(generate=False):
    source=['// Generated from testdata/upstream/manifest.json by scripts/check_diff.py.']
    for i,name in enumerate(inputs()):
        source+=['','///|',f'test "diff-upstream-{name}" {{',f'  diff_test_run("{name}",apply_fixture_{i}_old(),apply_fixture_{i}_new())','}']
    expected='\n'.join(source)+'\n';path=ROOT/'diff_vectors_test.mbt'
    if generate:path.write_text(expected,encoding='utf8',newline='\n')
    tokens=lambda text:re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|\d+|[^\s,]',text)
    assert tokens(path.read_text())==tokens(expected),'generated diff tests differ from fixture inventory'
    print('13 upstream old/new pairs and public diff test mapping verified offline')

def integer(raw):
    assert len(raw)==8
    magnitude=int.from_bytes(raw[:7]+bytes([raw[7]&127]),'little')
    value=-magnitude if raw[7]&128 else magnitude
    canonical=bytearray(abs(value).to_bytes(8,'little'))
    if value<0:canonical[7]|=128
    assert bytes(canonical)==raw,'noncanonical integer'
    return value

def parse(patch,old,new):
    assert len(patch)>=32 and patch[:8]==b'BSDIFF40'
    c,d,size=(integer(patch[i:i+8]) for i in (8,16,24))
    assert c>=0 and d>=0 and size==len(new)
    assert 32+c+d<=len(patch)
    blocks=[]
    for raw in (patch[32:32+c],patch[32+c:32+c+d],patch[32+c+d:]):
        assert raw[:4]==b'BZh9'
        decoder=bz2.BZ2Decompressor();plain=decoder.decompress(raw)
        assert decoder.eof and not decoder.unused_data,'not one complete stream'
        blocks.append(plain)
    control,difference,extra=blocks
    assert len(control)%24==0
    restored=bytearray();cursor=dp=ep=equal=residuals=reuse=0;triples=[]
    for at in range(0,len(control),24):
        assert len(restored)<size,'unused control'
        x,y,z=(integer(control[i:i+8]) for i in (at,at+8,at+16))
        assert x>=0 and y>=0 and x+y<=size-len(restored)
        assert x<=len(difference)-dp and y<=len(extra)-ep
        triples.append(dict(old_start=cursor,x=x,y=y,z=z))
        for i in range(x):
            byte=old[cursor+i] if 0<=cursor+i<len(old) else 0
            reuse+=int(0<=cursor+i<len(old))
            equal+=int(byte==new[len(restored)])
            residuals+=int(difference[dp+i]!=0)
            restored.append((byte+difference[dp+i])%256)
        dp+=x;restored.extend(extra[ep:ep+y]);ep+=y;cursor+=x+z
        assert -(2**63)<=cursor<2**63
    assert bytes(restored)==new and len(restored)==size
    assert dp==len(difference) and ep==len(extra)
    return dict(patch_size=len(patch),patch_sha256=sha(patch),control_count=len(triples),diff_bytes=dp,extra_bytes=ep,equal_old_bytes=equal,reused_old_bytes=reuse,nonzero_residual_bytes=residuals,controls=triples)

def oracle_record(path):
    from oracle_identity import verified_tools
    tools,record=verified_tools(path,required=('bspatch',))
    return tools['bspatch'],record['products']['bspatch']

def verify_log(path,use_oracle=False,record_path=None):
    expected=inputs();rows={}
    for line in path.read_text(encoding='utf-8-sig').splitlines():
        if line.startswith('DIFF:'):
            _,name,raw=line.split(':')
            assert name in expected and name not in rows,'unexpected/duplicate result'
            rows[name]=bytes.fromhex(raw)
    assert set(rows)==set(expected),'missing generated patch results'
    directory=ROOT/'_build/diff-verification';directory.mkdir(parents=True,exist_ok=True)
    binary,digest=oracle_record(record_path) if use_oracle else (None,None)
    results=[]
    for name,data in expected.items():
        work=directory/name;work.mkdir(exist_ok=True)
        for kind,raw in data.items():(work/(kind+'.bin')).write_bytes(raw)
        patch=rows[name];(work/'patch.bin').write_bytes(patch)
        try:
            details=parse(patch,data['old'],data['new'])
            if name=='identical':assert details['diff_bytes']==len(data['new']) and details['extra_bytes']==0
            if name=='periodic':assert details['equal_old_bytes']>=1400
            if name=='block-move':assert details['reused_old_bytes']==len(data['new']) and details['equal_old_bytes']==len(data['new']) and any(t['z']<0 for t in details['controls'])
            if name=='seeded-random':assert details['equal_old_bytes']>=1900 and details['nonzero_residual_bytes']>0
            if binary:
                output=work/'restored.bin';output.unlink(missing_ok=True)
                try:run=subprocess.run([str(binary),str(work/'old.bin'),str(output),str(work/'patch.bin')],capture_output=True,timeout=15)
                except subprocess.TimeoutExpired as error:
                    (work/'bspatch.stderr.log').write_bytes(error.stderr or b'');raise
                (work/'bspatch.stdout.log').write_bytes(run.stdout);(work/'bspatch.stderr.log').write_bytes(run.stderr)
                assert run.returncode==0,f'bspatch exit {run.returncode}'
                assert output.is_file() and output.read_bytes()==data['new'],'bspatch output mismatch/missing'
            results.append(dict(id=name,old_sha256=sha(data['old']),new_sha256=sha(data['new']),**details))
        except Exception as error:
            (work/'error.txt').write_text(repr(error),encoding='utf8')
            raise RuntimeError(f'{name}: verification failed, inputs/logs retained in {work}') from error
    report=dict(direction='MoonBSDiff diff -> Python independent parser'+(' -> BSDiff 4.3 bspatch' if binary else ''),exported_target='native' if binary else 'log supplied by caller',oracle_sha256=digest,environment=platform.platform(),cases=results)
    (directory/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print(f'{len(results)} generated patches: independent canonical integers, level-9 single streams, controls and full byte restoration passed')
    if binary:print(f'{len(results)} actual BSDiff 4.3 bspatch outputs matched original new files byte-for-byte')
    return report

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--generate-tests',action='store_true');parser.add_argument('--log',type=pathlib.Path);parser.add_argument('--oracle',action='store_true');parser.add_argument('--oracle-record',type=pathlib.Path,default=ROOT/'tools/oracle/verified-build.json');args=parser.parse_args()
    tests(args.generate_tests)
    if args.oracle and not args.log:parser.error('--oracle requires --log')
    if args.log:verify_log(args.log,args.oracle,args.oracle_record)
