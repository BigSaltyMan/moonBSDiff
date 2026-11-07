"""Strict protocol and fresh-output process checks shared by the matrix runner/tests."""
import json,pathlib,re,subprocess,time
class ConformanceError(ValueError):
    def __init__(self,kind,message):self.kind=kind;super().__init__(message)
def fail(kind,message):raise ConformanceError(kind,message)
def require(condition,message):
    if not condition:fail('protocol',message)
def unique_object(pairs):
    result={}
    for key,value in pairs:
        if key in result:fail('protocol','duplicate JSON key: '+key)
        result[key]=value
    return result
def read_json(text):
    try:return json.loads(text,object_pairs_hook=unique_object,parse_constant=lambda value:fail('protocol','invalid JSON constant'))
    except json.JSONDecodeError as error:fail('protocol','invalid JSON: '+str(error))
def compare(actual,expected):
    if actual!=expected:fail('mismatch','complete byte comparison failed')
def run_process(args,stem,output=None,timeout=30,cwd=None):
    stem=pathlib.Path(stem);stem.parent.mkdir(parents=True,exist_ok=True)
    if output is not None and output.exists():fail('stale-output','output existed before subprocess: '+str(output))
    record=dict(command=[str(a) for a in args],timeout_seconds=timeout)
    start=time.monotonic()
    try:
        result=subprocess.run([str(a) for a in args],capture_output=True,timeout=timeout,cwd=cwd)
        record.update(exit_code=result.returncode,elapsed_seconds=time.monotonic()-start)
        pathlib.Path(str(stem)+'.stdout.log').write_bytes(result.stdout);pathlib.Path(str(stem)+'.stderr.log').write_bytes(result.stderr)
    except subprocess.TimeoutExpired as error:
        record.update(status='timeout',elapsed_seconds=time.monotonic()-start)
        pathlib.Path(str(stem)+'.stdout.log').write_bytes(error.stdout or b'');pathlib.Path(str(stem)+'.stderr.log').write_bytes(error.stderr or b'')
        pathlib.Path(str(stem)+'.command.json').write_text(json.dumps(record,indent=2)+'\n');fail('timeout','subprocess timeout: '+str(args))
    except OSError as error:
        record.update(status='environment-error',error=str(error));pathlib.Path(str(stem)+'.command.json').write_text(json.dumps(record,indent=2)+'\n');fail('environment','subprocess unavailable: '+str(error))
    pathlib.Path(str(stem)+'.command.json').write_text(json.dumps(record,indent=2)+'\n')
    if result.returncode!=0:fail('process','nonzero exit '+str(result.returncode)+': '+str(args))
    if output is not None and not output.is_file():fail('process','successful subprocess did not create output')
    return result

def validate_rows(records,request,target,case_ids,case_map,directions=('oracle-to-moon','moon-to-oracle'),kinds=None):
    if kinds is None:kinds={'oracle-to-moon':'restored','moon-to-oracle':'restored'}
    rows={}
    keys={'schema','run_id','manifest_sha256','case_id','target','direction','old_sha256','new_sha256','status','payload_kind','payload_hex'}
    for row in records:
        require(type(row) is dict and set(row)==keys,'unexpected result fields')
        require(type(row['schema']) is int and row['schema']==1,'wrong schema')
        require(all(type(row[k]) is str for k in keys-{'schema'}),'result fields must be strings')
        require(row['run_id']==request['run_id'] and row['manifest_sha256']==request['manifest_sha256'],'stale/wrong run or manifest')
        require(row['target']==target and row['case_id'] in case_ids,'wrong target/case')
        require(row['direction'] in directions and row['status']=='ok','wrong direction/status')
        require(row['payload_kind']==kinds[row['direction']],'wrong payload kind')
        source=case_map[row['case_id']]
        require(row['old_sha256']==source['old_sha256'] and row['new_sha256']==source['new_sha256'],'input identity mismatch')
        require(re.fullmatch('(?:[0-9a-f]{2})*',row['payload_hex']) is not None,'invalid canonical hex')
        key=(row['case_id'],row['direction']);require(key not in rows,'duplicate result identity')
        rows[key]=bytes.fromhex(row['payload_hex'])
    expected={(cid,direction) for cid in case_ids for direction in directions}
    require(set(rows)==expected,'missing/extra result set')
    return rows

def parse_moon_log(text,request,target,case_ids,case_map):
    records=[];summaries=[]
    for line in text.splitlines():
        if line.startswith('CONFORMANCE:'):records.append(read_json(line[len('CONFORMANCE:'):]))
        else:
            match=re.fullmatch(r'Total tests: (\d+), passed: (\d+), failed: (\d+)\.',line)
            require(match is not None,'unexpected stdout line: '+line)
            summaries.append(tuple(map(int,match.groups())))
    require(summaries==[(len(case_ids),len(case_ids),0)],'missing/duplicate/wrong execution summary')
    return validate_rows(records,request,target,case_ids,case_map,kinds={'oracle-to-moon':'restored','moon-to-oracle':'patch'})
