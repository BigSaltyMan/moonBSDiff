"""Commit 19 only: SHA-256 manifests and two-output no-overwrite/partial delivery."""
import argparse,contextlib,getpass,hashlib,json,os,pathlib,platform,subprocess,unittest
import test_cli as shared
from build_cli import ROOT,version

def entry(raw):return dict(size_bytes=str(len(raw)),sha256=hashlib.sha256(raw).hexdigest())
class ManifestCli(unittest.TestCase):
    setUp=shared.CliFiles.setUp
    run_cli=shared.CliFiles.run_cli
    def generate(self,manifest,patch=None,code=0):
        result=self.run_cli(['diff','--manifest',manifest,self.old,self.new,patch or self.patch],code)
        self.assertEqual(result.stdout,b'');return result
    def check_manifest(self,path,patch):
        raw=path.read_bytes();self.assertTrue(raw.endswith(b'\n'))
        doc=json.loads(raw);self.assertIs(type(doc['schema_version']),int)
        self.assertEqual(doc,dict(schema_version=1,patch_format='BSDIFF40',producer=dict(name='moonbsdiff',version=version()),old=entry(self.old.read_bytes()),new=entry(self.new.read_bytes()),patch=entry(patch.read_bytes())))
        for key in ['old','new','patch']:self.assertRegex(doc[key]['sha256'],r'^[0-9a-f]{64}$')
        return raw
    def test_hashes_and_stable_patch_manifest(self):
        plain=self.p/'plain.patch';self.run_cli(['diff',self.old,self.new,plain])
        manifest=self.p/'manifest.json';self.generate(manifest);first=self.check_manifest(manifest,self.patch)
        self.assertEqual(self.patch.read_bytes(),plain.read_bytes());self.assertTrue(self.patch.read_bytes().startswith(b'BSDIFF40'))
        other=self.p/'again.patch';second=self.p/'again.json';self.generate(second,other)
        self.assertEqual(self.check_manifest(second,other),first);self.assertEqual(other.read_bytes(),self.patch.read_bytes())
    def test_empty_inputs_and_dash_paths(self):
        self.old.write_bytes(b'');self.new.write_bytes(b'');m=self.p/'empty.json';self.generate(m);self.check_manifest(m,self.patch)
        for name in ['-old','-new']:(self.p/name).write_bytes(b'\x00\xff')
        with contextlib.chdir(self.p):self.run_cli(['diff','--manifest','./-manifest.json','--','-old','-new','-patch'])
        d=json.loads((self.p/'-manifest.json').read_bytes());self.assertEqual(d['old'],entry(b'\x00\xff'));self.assertEqual(d['new'],entry(b'\x00\xff'))
    def test_invalid_arguments(self):
        rows=[['diff','--manifest'],['diff','--manifest',''],['diff','--manifest','--show-limits'],['patch','--manifest'],['diff','--manifest','a','--manifest','b',self.old,self.new,self.patch],['inspect','--manifest','a',self.patch],['diff','--manifest','a','--show-limits']]
        for args in rows:
            with self.subTest(args=args):self.run_cli(args,2);self.assertFalse(self.patch.exists())
    def test_output_conflicts_and_parent_aliases(self):
        m=self.p/'manifest.json';m.write_bytes(b'keep')
        self.generate(m,code=1);self.assertEqual(m.read_bytes(),b'keep');self.assertFalse(self.patch.exists())
        for target in [self.old,self.new,self.patch]:
            with self.subTest(target=target):self.generate(target,code=1);self.assertFalse(self.patch.exists())
        real=self.p/'real';real.mkdir();alias=self.p/'alias'
        if os.name=='nt':
            r=subprocess.run(['cmd','/c','mklink','/J',str(alias),str(real)],capture_output=True);self.assertEqual(r.returncode,0,r.stderr)
        else:alias.symlink_to(real,target_is_directory=True)
        try:
            patch=real/'same.patch';r=self.generate(alias/'same.patch',patch,code=1)
            self.assertIn(b'same target',r.stderr);self.assertFalse(patch.exists())
            if os.name=='nt':
                for name in ['SAME.PATCH','same.patch.','same.patch ']:
                    r=self.generate(real/name,patch,code=1);self.assertIn(b'same target',r.stderr);self.assertFalse(patch.exists())
        finally:
            if os.name=='nt':alias.rmdir()
            else:alias.unlink()
    def test_second_delivery_failure_keeps_patch(self):
        locked=self.p/'locked';locked.mkdir();m=locked/'manifest.json'
        if os.name=='nt':
            user=os.environ.get('USERDOMAIN','')+'\\'+getpass.getuser()
            result=subprocess.run(['icacls',str(locked),'/deny',user+':(WD,AD)'],capture_output=True);self.assertEqual(result.returncode,0)
        else:locked.chmod(0o500)
        try:
            with self.assertRaises(PermissionError):(locked/'probe').write_bytes(b'x')
            r=self.generate(m,code=1)
            for text in ['patch delivered','manifest not completed','no rollback attempted']:self.assertIn(text.encode(),r.stderr)
            self.assertTrue(self.patch.is_file());self.assertTrue(self.patch.read_bytes().startswith(b'BSDIFF40'));self.assertFalse(m.exists());self.assertEqual(list(locked.iterdir()),[])
        finally:
            if os.name=='nt':
                result=subprocess.run(['icacls',str(locked),'/remove:d',user],capture_output=True);self.assertEqual(result.returncode,0)
            else:locked.chmod(0o700)
        # A partial operation cannot be retried over the delivered patch.
        before=self.patch.read_bytes();self.generate(m,code=1);self.assertEqual(self.patch.read_bytes(),before);self.assertFalse(m.exists())

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',required=True,type=pathlib.Path);a=p.parse_args();shared.EXE=a.exe.resolve()
    if not shared.EXE.is_file():raise SystemExit('CLI executable missing')
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ManifestCli))
    report=dict(platform=platform.system(),tests=result.testsRun,failed=len(result.failures)+len(result.errors),skipped=len(result.skipped),cli_invocations=shared.INVOCATIONS,scope='Commit 19 only; independent hashlib; no old suite or oracle')
    (ROOT/'_build'/('cli-manifest-'+platform.system()+'.json')).write_text(json.dumps(report,indent=2)+'\n',encoding='utf8');print(json.dumps(report))
    if not result.wasSuccessful() or not result.testsRun or result.skipped:raise SystemExit(1)
