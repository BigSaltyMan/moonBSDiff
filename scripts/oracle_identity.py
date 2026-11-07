"""Single identity check for the locked BSDiff tools (never builds/downloads)."""
import hashlib,json,pathlib
ROOT=pathlib.Path(__file__).resolve().parents[1]
def verified_tools(record_path=None, required=("bsdiff","bspatch")):
    lock_path=ROOT/"tools/oracle/upstream.lock.json"
    lock=json.loads(lock_path.read_text());record=json.loads((record_path or ROOT/"tools/oracle/verified-build.json").read_text())
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    if lock['bsdiff']['version']!='4.3' or record['lock_sha256']!=sha(lock_path):raise ValueError('oracle lock/version mismatch')
    for name,digest in lock['bsdiff']['files'].items():
        if sha(ROOT/'_build/oracle/bsdiff-4.3'/name)!=digest:raise ValueError('oracle source mismatch: '+name)
    tools={}
    for name in required:
        if name not in ('bsdiff','bspatch'):raise ValueError('unknown oracle tool')
        path=ROOT/'_build/oracle'/name
        if sha(path)!=record['products'][name]:raise ValueError('oracle binary hash mismatch: '+name)
        tools[name]=path
    return tools,record
