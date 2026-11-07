"""Derived inventory: fixed upstream inputs plus explicit LCG32 edit recipes."""
import hashlib,json,pathlib
from check_diff import inputs
ROOT=pathlib.Path(__file__).resolve().parents[1]
MANIFEST=ROOT/'testdata/conformance/manifest.json'
SEEDS=[2026110701,2026110702,2026110703]
SIZES=[128,512,2048]
KINDS=['sparse','insert','delete','prepend','append','truncate']
def sha(raw):return hashlib.sha256(raw).hexdigest()
def lcg(seed,count):
    state=seed;result=bytearray()
    for _ in range(count):
        state=(1664525*state+1013904223)&0xffffffff;result.append(state>>24)
    return bytes(result)
def inventory():
    rows=[];data={}
    for name,value in inputs().items():
        data[name]=value;rows.append(dict(id=name,source={'kind':'upstream','id':name},old_size=len(value['old']),new_size=len(value['new']),old_sha256=sha(value['old']),new_sha256=sha(value['new'])))
    for seed,n in zip(SEEDS,SIZES):
        old=lcg(seed,n)
        for kind in KINDS:
            name=f'rnd-{seed}-{kind}';params={}
            if kind=='sparse':
                positions=[n//7,n//3,n//2,n-1];masks=[1,128,255,85];edited=bytearray(old)
                for pos,mask in zip(positions,masks):edited[pos]^=mask
                new=bytes(edited);params=dict(positions=positions,xor=masks)
            elif kind=='insert':
                at=n//2;added=lcg(seed^0x9e3779b9,17);new=old[:at]+added+old[at:];params=dict(at=at,length=17,seed_xor=0x9e3779b9)
            elif kind=='delete':
                at=n//3;length=min(n//5,31);new=old[:at]+old[at+length:];params=dict(at=at,length=length)
            elif kind=='prepend':new=lcg(seed^0xabcdef,13)+old;params=dict(length=13,seed_xor=0xabcdef)
            elif kind=='append':new=old+lcg(seed^0xf00d,19);params=dict(length=19,seed_xor=0xf00d)
            else:new=old[:-23];params=dict(length=23)
            data[name]=dict(old=old,new=new)
            rows.append(dict(id=name,source=dict(kind='lcg32-v1',seed=seed,old_size=n,edit=kind,parameters=params),old_size=len(old),new_size=len(new),old_sha256=sha(old),new_sha256=sha(new)))
    return rows,data

def expected_manifest():
    rows,_=inventory();base=[r['id'] for r in rows[:13]];compact=base+[r['id'] for r in rows[13:19]]
    return dict(schema=1,upstream_manifest_sha256=sha((ROOT/'testdata/upstream/manifest.json').read_bytes()),generator='LCG32 v1: state=(1664525*state+1013904223) mod 2^32; emit high byte; independent of Python random versions',cases=rows,matrix=dict(native=[r['id'] for r in rows],js=compact,**{'wasm-gc':compact}))
def load_manifest():
    actual=json.loads(MANIFEST.read_text());expected=expected_manifest()
    if actual!=expected:raise ValueError('conformance inventory/recipe/hash/matrix mismatch')
    return actual,inventory()[1]
def write_manifest():
    MANIFEST.parent.mkdir(parents=True,exist_ok=True);MANIFEST.write_text(json.dumps(expected_manifest(),indent=2)+'\n',encoding='utf8',newline='\n')
