"""Offline bzip2 fixtures; --generate is explicit. --log verifies emitted MoonBit streams."""
import argparse, bz2, hashlib, json, pathlib, re, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
DATA = ROOT / 'testdata/compression'

def body(name):
    if name == 'empty': return b''
    if name == 'binary': return b'BSDIFF40\x00\xff\x01\x80'
    if name == 'all': return bytes(range(256))
    if name == 'repeat': return b'A' * 4096
    sizes = {'near1':99980, 'cross1':110080, 'near9':899980, 'cross9':921600}
    return (bytes(range(256))*((sizes[name]+255)//256))[:sizes[name]]

def cases():
    return [(n,l) for n in ['empty','binary','all','repeat'] for l in [1,9]] + [('near1',1),('cross1',1),('near9',9),('cross9',9)]

def sha(b): return hashlib.sha256(b).hexdigest()

def generate():
    DATA.mkdir(parents=True,exist_ok=True)
    rows=[]; source=['// Generated small compressed literals; reconstruct expanded inputs algorithmically.','// Source and hashes: testdata/compression/manifest.json.']
    for name,level in cases():
        plain=body(name); packed=bz2.compress(plain,compresslevel=level); key=f'{name}_{level}'
        (DATA/(key+'.bz2')).write_bytes(packed)
        rows.append(dict(id=key, input_size=len(plain), input_sha256=sha(plain), compressed_size=len(packed), compressed_sha256=sha(packed)))
        source += ['','///|',f'fn compression_fixture_{key}() -> Bytes {{']
        chunks=[packed[i:i+48] for i in range(0,len(packed),48)]
        source += ['  b"'+''.join(f'\\x{x:02x}' for x in c)+'"'+(' +' if i<len(chunks)-1 else '') for i,c in enumerate(chunks)]
        source += ['}']
    (ROOT/'compression_vectors_wbtest.mbt').write_text('\n'.join(source)+'\n',encoding='utf8')
    (DATA/'manifest.json').write_text(json.dumps({'generator':'Python bz2.compress; inputs in scripts/check_compression.py', 'python':sys.version.split()[0], 'cases':rows},indent=2)+'\n')

def strict(packed, expected):
    dec=bz2.BZ2Decompressor(); out=dec.decompress(packed)
    assert dec.eof and dec.unused_data==b'', 'not exactly one complete bzip2 stream'
    assert out==expected, 'content mismatch'

def verify():
    manifest=json.loads((DATA/'manifest.json').read_text())
    assert [r['id'] for r in manifest['cases']]==[f'{n}_{l}' for n,l in cases()]
    source=(ROOT/'compression_vectors_wbtest.mbt').read_text()
    for row,(name,level) in zip(manifest['cases'],cases()):
        packed=(DATA/(row['id']+'.bz2')).read_bytes(); plain=body(name)
        assert len(plain)==row['input_size'] and sha(plain)==row['input_sha256']
        assert len(packed)==row['compressed_size'] and sha(packed)==row['compressed_sha256']
        section=source.split(f'fn compression_fixture_{row["id"]}()',1)[1].split('}',1)[0]
        embedded=bytes(int(x,16) for x in re.findall(r'\\x([0-9a-f]{2})',section))
        assert embedded==packed, 'fixture source mismatch'
        assert packed[:4]==b'BZh'+bytes([48+level])
        strict(packed,plain)
    assert {p.name for p in DATA.glob('*.bz2')} == {row['id']+'.bz2' for row in manifest['cases']}
    lock=json.loads((ROOT/'internal/bzip2/source-lock.json').read_text())
    for name, expected in lock['adapted_files'].items():
        assert sha((ROOT/'internal/bzip2'/name).read_bytes()) == expected, 'adapted source hash mismatch: '+name
    print(f'compression fixtures: {len(cases())} verified offline')

def verify_log(path, large=False):
    rows={}
    for line in pathlib.Path(path).read_text(encoding='utf-8-sig').splitlines():
        if line.startswith('COMPRESSION:'):
            _,name,hexdata=line.split(':'); assert name not in rows; rows[name]=bytes.fromhex(hexdata)
    expected=['empty','binary','all','repeat']
    if large: expected+=['cross9']
    assert set(rows)==set(expected), f'missing/extra results: {set(rows)}'
    for name,packed in rows.items():
        assert packed[:4]==b'BZh9', 'encoder is not level 9'
        strict(packed,body(name))
    print(f'MoonBit -> Python: {len(rows)} level-9 strict streams verified')

if __name__=='__main__':
    p=argparse.ArgumentParser(__doc__); p.add_argument('--generate',action='store_true'); p.add_argument('--log'); p.add_argument('--large',action='store_true'); args=p.parse_args()
    if args.generate: generate()
    verify()
    if args.log: verify_log(args.log, args.large)
