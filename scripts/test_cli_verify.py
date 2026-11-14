"""Commit 20 only: bounded manifest parsing, identity, restore and checked delivery."""
import argparse,copy,hashlib,json,pathlib,platform,unittest
import test_cli as shared
from build_cli import ROOT
FIXTURE=ROOT/'testdata/manifest'
def entry(raw):return dict(size_bytes=str(len(raw)),sha256=hashlib.sha256(raw).hexdigest())

class VerifyCli(unittest.TestCase):
    def setUp(self):
        shared.CliFiles.setUp(self);self.manifest=self.p/'update.json'
        self.old.write_bytes((FIXTURE/'old.bin').read_bytes());self.new.write_bytes((FIXTURE/'new.bin').read_bytes());self.patch.write_bytes((FIXTURE/'update.patch').read_bytes());self.manifest.write_bytes((FIXTURE/'update.json').read_bytes());self.doc=json.loads(self.manifest.read_bytes())
        for key,p in [('old',self.old),('new',self.new),('patch',self.patch)]:self.assertEqual(entry(p.read_bytes()),self.doc[key])
    def invoke(self,args,code=0):
        before={p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.p.iterdir()}
        r=shared.CliFiles.run_cli(self,args,code)
        for name,state in before.items():p=self.p/name;self.assertEqual((p.read_bytes(),p.stat().st_mtime_ns),state)
        if code:self.assertEqual(before,{p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.p.iterdir()})
        return r
    def verify(self,code=0,options=()):return self.invoke(['verify',*options,'--manifest',self.manifest,self.old,self.patch],code)
    def patch_with_manifest(self,code=0,output=None):return self.invoke(['patch','--manifest',self.manifest,self.old,self.patch,output or self.out],code)
    def write_doc(self,d):self.manifest.write_text(json.dumps(d),encoding='utf8')
    def test_valid_verify_and_checked_patch(self):
        before=set(self.p.iterdir());r=self.verify();self.assertIn(b'Verification succeeded:',r.stdout);self.assertEqual(set(self.p.iterdir()),before)
        raw=self.manifest.read_bytes();self.manifest.write_bytes(raw+b' '*(16384-len(raw)));self.verify()
        d=copy.deepcopy(self.doc);d['producer']={'name':'opaque metadata, not a file path','version':'999-not-trusted'};self.write_doc(d);self.verify()
        self.patch_with_manifest();self.assertEqual(self.out.read_bytes(),self.new.read_bytes())
        self.old.write_bytes(b'');self.new.write_bytes(b'');self.patch.write_bytes((ROOT/'testdata/upstream/both-empty/patch.bin').read_bytes())
        d=copy.deepcopy(self.doc)
        for key,p in [('old',self.old),('new',self.new),('patch',self.patch)]:d[key]=entry(p.read_bytes())
        self.write_doc(d);self.verify();empty=self.p/'empty-output';self.patch_with_manifest(output=empty);self.assertEqual(empty.read_bytes(),b'')
    def test_identity_and_restoration_mismatch(self):
        old=self.old.read_bytes();patch=self.patch.read_bytes()
        self.old.write_bytes(bytes([old[0]^1])+old[1:]);r=self.verify(1);self.assertIn(b'old input sha256 mismatch',r.stderr);self.old.write_bytes(old)
        self.patch.write_bytes(bytes([patch[0]^1])+patch[1:]);r=self.patch_with_manifest(1);self.assertIn(b'patch input sha256 mismatch',r.stderr);self.patch.write_bytes(patch)
        for key,field,value,fragment in [('old','size_bytes','4','old input size mismatch'),('patch','size_bytes','154','patch input size mismatch'),('new','size_bytes','7','patch header/new size mismatch'),('new','sha256','0'*64,'restored new content sha256 mismatch')]:
            d=copy.deepcopy(self.doc);d[key][field]=value;self.write_doc(d)
            with self.subTest(key=key,field=field):r=self.patch_with_manifest(1);self.assertIn(fragment.encode(),r.stderr)
        # Identity can match a corrupt payload; only real apply rejects this case.
        damaged=patch[:32]+bytes([patch[32]^1])+patch[33:];self.patch.write_bytes(damaged)
        d=copy.deepcopy(self.doc);d['patch']=entry(damaged);self.write_doc(d)
        r=self.patch_with_manifest(1);self.assertIn(b'restoration apply:',r.stderr)
        self.assertFalse(self.out.exists())
    def test_schema_read_bound_and_duplicate_keys(self):
        raw=json.dumps(self.doc);rows=[]
        def changed(key,field,value):d=copy.deepcopy(self.doc);d[key][field]=value;return json.dumps(d).encode()
        d=copy.deepcopy(self.doc);del d['old']['sha256'];rows.append((json.dumps(d).encode(),'missing old.sha256'))
        rows.extend([(changed('old','size_bytes',5),'must be a string'),(changed('new','size_bytes','-1'),'nonnegative ASCII'),(changed('new','size_bytes','9223372036854775808'),'overflows Int64'),(changed('patch','sha256','A'*64),'lowercase hex')])
        rows.append((raw.replace('"schema_version": 1','"schema_version": 1, "schema_version": 1').encode(),'DuplicateKey'))
        rows.append((raw.replace('"size_bytes": "5"','"size_bytes": "5", "\\u0073ize_bytes": "5"').encode(),'DuplicateKey'))
        for key,value,fragment in [('schema_version',2,'schema_version'),('schema_version',1.0,'schema_version'),('patch_format','BSDIFF43','patch_format'),('path','must-not-be-opened','unknown fields')]:
            d=copy.deepcopy(self.doc);d[key]=value;rows.append((json.dumps(d).encode(),fragment))
        rows.extend([(b' '*16385,'byte limit 16384'),(b'\xff','valid UTF-8'),(b'['*10+b'0'+b']'*10,'DepthLimitExceeded')])
        for raw,fragment in rows:
            self.manifest.write_bytes(raw)
            with self.subTest(fragment=fragment):r=self.patch_with_manifest(1);self.assertIn(fragment.encode(),r.stderr)
    def test_limits_and_output_preservation(self):
        r=self.verify(1,options=['--max-old-bytes','4']);self.assertIn(b'manifest limits: old/max_old_bytes',r.stderr)
        r=self.verify(1,options=['--max-output-bytes','5']);self.assertIn(b'manifest limits: new/max_output_bytes',r.stderr)
        r=self.invoke(['verify','--max-old-bytes','4','--manifest',self.manifest,self.p/'missing-old',self.p/'missing-patch'],1);self.assertIn(b'manifest limits:',r.stderr)
        for p in [self.old,self.patch,self.manifest]:self.patch_with_manifest(1,output=p)
        self.out.write_bytes(b'keep');self.patch_with_manifest(1);self.assertEqual(self.out.read_bytes(),b'keep')
        alias=self.p/'manifest-alias';alias.hardlink_to(self.manifest);self.patch_with_manifest(1,output=alias);self.assertEqual(alias.read_bytes(),self.manifest.read_bytes())
    def test_verify_arguments(self):
        rows=[['verify',self.old,self.patch],['verify','--manifest'],['verify','--manifest',self.manifest,self.old,self.patch,self.out],['verify','--manifest',self.manifest,'--manifest',self.manifest,self.old,self.patch],['verify','--manifest',self.manifest,'--max-sort-work','1',self.old,self.patch],['verify','--manifest',self.manifest,'--max-match-work','1',self.old,self.patch],['verify','--show-limits'],['verify','--json','--manifest',self.manifest,self.old,self.patch]]
        for args in rows:
            with self.subTest(args=args):self.invoke(args,2)
        for src,name in [(self.old,'-old'),(self.patch,'-patch'),(self.manifest,'-manifest')]: (self.p/name).write_bytes(src.read_bytes())
        import contextlib
        with contextlib.chdir(self.p):self.invoke(['verify','--manifest','./-manifest','--','-old','-patch'])

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',required=True,type=pathlib.Path);a=p.parse_args();shared.EXE=a.exe.resolve()
    if not shared.EXE.is_file():raise SystemExit('CLI executable missing')
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(VerifyCli))
    report=dict(platform=platform.system(),tests=result.testsRun,failed=len(result.failures)+len(result.errors),skipped=len(result.skipped),cli_invocations=shared.INVOCATIONS,scope='Commit 20 only; reused fixed Commit 19 fixture; no old suite/oracle')
    (ROOT/'_build'/('cli-verify-'+platform.system()+'.json')).write_text(json.dumps(report,indent=2)+'\n',encoding='utf8');print(json.dumps(report))
    if not result.wasSuccessful() or not result.testsRun or result.skipped:raise SystemExit(1)
