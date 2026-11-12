"""Real native CLI subprocess contract tests; no oracle, network or large benchmark."""
import argparse,bz2,ctypes,getpass,hashlib,json,os,pathlib,platform,subprocess,sys,tempfile,unittest
from build_cli import ROOT,version
from conformance_cases import lcg
EXE=None
INVOCATIONS=0
LARGE_PATCH={}

class CliFiles(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='moonbsdiff-cli-');self.addCleanup(self.temp.cleanup);self.p=pathlib.Path(self.temp.name)
        self.old=self.p/'old.bin';self.new=self.p/'new.bin';self.patch=self.p/'patch.bin';self.out=self.p/'output.bin'
        self.old.write_bytes(b'abc\x00\xff');self.new.write_bytes(b'abC\x00\xff!')
    def run_cli(self,args,code=0):
        global INVOCATIONS
        INVOCATIONS+=1
        before={}
        for p in self.p.iterdir():
            if p.is_file() and not p.is_symlink():
                try:before[str(p)]=p.read_bytes()
                except PermissionError:pass
        result=subprocess.run([str(EXE),*map(str,args)],cwd=self.p,capture_output=True,timeout=30)
        self.assertEqual(result.returncode,code,result.stderr.decode('utf8',errors='replace'))
        if code:
            self.assertEqual(result.stdout,b'');self.assertTrue(result.stderr)
            for name,raw in before.items():self.assertEqual(pathlib.Path(name).read_bytes(),raw,name)
            self.assertFalse(list(self.p.glob('.moonbsdiff-*.tmp')))
        else:self.assertEqual(result.stderr,b'')
        return result
    def generate(self):self.run_cli(['diff',self.old,self.new,self.patch])
    def roundtrip(self):
        self.generate();self.run_cli(['patch',self.old,self.patch,self.out]);self.assertEqual(self.out.read_bytes(),self.new.read_bytes())
    def test_help_version(self):
        h=self.run_cli(['--help']);self.assertIn(b'patch OLD_FILE PATCH_FILE OUTPUT_FILE',h.stdout);self.assertIn(b'131072',h.stdout);self.assertIn(b'never replaced',h.stdout)
        self.assertEqual(self.run_cli(['--version']).stdout.decode('utf8').strip(),'moonbsdiff '+version())
    def test_arguments(self):
        for args in [[],['unknown'],['diff'],['patch'],['diff','a','b'],['patch','a','b'],['diff','a','b','c','d'],['patch','a','b','c','d'],['--help','extra'],['--version','extra']]:
            with self.subTest(args=args):self.run_cli(args,2)
    def test_binary_roundtrip(self):self.roundtrip()
    def test_empty_roundtrip(self):
        self.old.write_bytes(b'');self.new.write_bytes(b'');self.roundtrip();self.assertEqual(self.out.stat().st_size,0)
    def test_old_empty_roundtrip(self):self.old.write_bytes(b'');self.roundtrip()
    def test_new_empty_roundtrip(self):self.new.write_bytes(b'');self.roundtrip()
    def test_identical_roundtrip(self):self.new.write_bytes(self.old.read_bytes());self.roundtrip()
    def test_unicode_spaces_relative_absolute(self):
        folder=self.p/'\u4e2d\u6587 directory';folder.mkdir()
        self.old.rename(folder/'\u65e7 \u6587\u4ef6.bin');self.new.rename(folder/'\u65b0 \u6587\u4ef6.bin')
        old=folder/'\u65e7 \u6587\u4ef6.bin';new=folder/'\u65b0 \u6587\u4ef6.bin';patch=folder/'\u5dee \u5206.patch';out=folder/'\u6062\u590d.bin'
        self.run_cli(['diff',old.relative_to(self.p),new,patch.relative_to(self.p)])
        self.run_cli(['patch',old,patch,out.relative_to(self.p)]);self.assertEqual(out.read_bytes(),new.read_bytes())
    def test_patch_over_64k(self):
        self.old.write_bytes(lcg(2026110801+65536,65536));self.new.write_bytes(lcg(2026110803+65536,65536))
        self.roundtrip();self.assertGreater(self.patch.stat().st_size,65536);self.assertLessEqual(self.patch.stat().st_size,131072)
        LARGE_PATCH.update(old_bytes=self.old.stat().st_size,new_bytes=self.new.stat().st_size,patch_bytes=self.patch.stat().st_size,old_sha256=hashlib.sha256(self.old.read_bytes()).hexdigest(),new_sha256=hashlib.sha256(self.new.read_bytes()).hexdigest(),patch_sha256=hashlib.sha256(self.patch.read_bytes()).hexdigest(),recipe='LCG32 v1 independent old/new, seeds 2026110801+65536 and 2026110803+65536')
    def test_missing_input(self):self.run_cli(['diff','missing',self.new,self.patch],1);self.assertFalse(self.patch.exists())
    def test_directory_input(self):self.run_cli(['diff',self.p,self.new,self.patch],1);self.assertFalse(self.patch.exists())
    def test_old_over_limit(self):self.old.write_bytes(b'X'*65537);r=self.run_cli(['diff',self.old,self.new,self.patch],1);self.assertIn(b'input size',r.stderr);self.assertFalse(self.patch.exists())
    def test_new_over_limit(self):self.new.write_bytes(b'Y'*65537);self.run_cli(['diff',self.old,self.new,self.patch],1);self.assertFalse(self.patch.exists())
    def test_patch_over_limit(self):self.patch.write_bytes(b'Z'*131073);self.run_cli(['patch',self.old,self.patch,self.out],1);self.assertFalse(self.out.exists())
    def test_apply_old_over_limit(self):self.generate();self.old.write_bytes(b'X'*1048577);self.run_cli(['patch',self.old,self.patch,self.out],1);self.assertFalse(self.out.exists())
    def test_invalid_patch(self):
        self.patch.write_bytes(b'invalid');r=self.run_cli(['patch',self.old,self.patch,self.out],1);self.assertIn(b'TruncatedData',r.stderr);self.assertIn(b'Header',r.stderr);self.assertFalse(self.out.exists())
    def test_corrupt_crc(self):
        self.generate();b=bytearray(self.patch.read_bytes())
        # The final byte can contain unused padding. The preceding byte is CRC.
        b[-2]^=1
        c=int.from_bytes(b[8:16],'little');d=int.from_bytes(b[16:24],'little')
        with self.assertRaises(OSError):bz2.decompress(bytes(b[32+c+d:]))
        self.patch.write_bytes(b);r=self.run_cli(['patch',self.old,self.patch,self.out],1);self.assertIn(b'DecompressionFailed',r.stderr);self.assertFalse(self.out.exists())
    def test_existing_diff_target(self):self.patch.write_bytes(b'keep');self.run_cli(['diff',self.old,self.new,self.patch],1)
    def test_existing_patch_target(self):self.generate();self.out.write_bytes(b'keep');self.run_cli(['patch',self.old,self.patch,self.out],1)
    def test_output_same_old(self):r=self.run_cli(['diff',self.old,self.new,self.old],1);self.assertIn(b'same file',r.stderr)
    def test_output_same_second(self):r=self.run_cli(['diff',self.old,self.new,self.new],1);self.assertIn(b'same file',r.stderr)
    def test_normalized_alias(self):
        sub=self.p/'sub';sub.mkdir();alias=sub/'..'/'old.bin';r=self.run_cli(['diff','old.bin',self.new,alias],1);self.assertIn(b'same file',r.stderr)
    def test_hardlink_output(self):
        try:os.link(self.old,self.out)
        except OSError as e:self.skipTest('hard links unavailable: '+str(e))
        r=self.run_cli(['diff',self.old,self.new,self.out],1);self.assertIn(b'same file',r.stderr)
    def test_symlink_output(self):
        try:self.out.symlink_to(self.old)
        except OSError as e:self.skipTest('symlink permission/support unavailable; OS code '+str(getattr(e,'winerror',e.errno)))
        r=self.run_cli(['diff',self.old,self.new,self.out],1);self.assertIn(b'same file',r.stderr);self.assertTrue(self.out.is_symlink())
    def test_dangling_symlink_output(self):
        target=self.p/'nonexistent'
        try:self.out.symlink_to(target)
        except OSError as e:self.skipTest('symlink permission/support unavailable; OS code '+str(getattr(e,'winerror',e.errno)))
        self.run_cli(['diff',self.old,self.new,self.out],1);self.assertTrue(self.out.is_symlink());self.assertFalse(target.exists())
    def test_directory_alias_identity(self):
        real=self.p/'real';real.mkdir();source=real/'input';source.write_bytes(b'input')
        alias=self.p/'alias'
        if os.name=='nt':
            r=subprocess.run(['cmd','/c','mklink','/J',str(alias),str(real)],capture_output=True)
            if r.returncode:self.skipTest('directory junction creation unavailable')
        else:alias.symlink_to(real,target_is_directory=True)
        try:
            r=self.run_cli(['diff',source,self.new,alias/'input'],1);self.assertIn(b'same file',r.stderr);self.assertEqual(source.read_bytes(),b'input')
        finally:
            if os.name=='nt':os.rmdir(alias)
            else:alias.unlink()
    def test_missing_output_parent(self):self.run_cli(['diff',self.old,self.new,self.p/'missing'/'patch'],1)
    def test_parent_is_file(self):self.run_cli(['diff',self.old,self.new,self.new/'patch'],1)
    def test_unreadable_input(self):
        if os.name=='nt':
            kernel=ctypes.WinDLL('kernel32',use_last_error=True)
            create=kernel.CreateFileW;create.argtypes=[ctypes.c_wchar_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_void_p];create.restype=ctypes.c_void_p
            handle=create(str(self.old),0x80000000,0,None,3,0,None)
            self.assertNotIn(handle,[None,ctypes.c_void_p(-1).value]);kernel.CloseHandle.argtypes=[ctypes.c_void_p]
            try:
                # The same real sharing lock must reject an independent open.
                with self.assertRaises(PermissionError):self.old.read_bytes()
                r=subprocess.run([str(EXE),'diff',str(self.old),str(self.new),str(self.patch)],capture_output=True,timeout=30)
                global INVOCATIONS
                INVOCATIONS+=1;self.assertEqual(r.returncode,1);self.assertFalse(r.stdout);self.assertIn(b'open input',r.stderr);self.assertFalse(self.patch.exists())
            finally:self.assertTrue(kernel.CloseHandle(handle))
            self.assertEqual(self.old.read_bytes(),b'abc\x00\xff')
        else:
            self.old.chmod(0)
            try:
                try:self.old.read_bytes()
                except PermissionError:pass
                else:self.skipTest('current identity bypasses read permissions')
                self.run_cli(['diff',self.old,self.new,self.patch],1)
            finally:self.old.chmod(0o600)
            self.assertEqual(self.old.read_bytes(),b'abc\x00\xff')
    def test_unwritable_output_directory(self):
        folder=self.p/'locked';folder.mkdir()
        if os.name=='nt':
            user=os.environ.get('USERDOMAIN','')+'\\'+getpass.getuser()
            r=subprocess.run(['icacls',str(folder),'/deny',user+':(WD,AD)'],capture_output=True)
            if r.returncode:self.skipTest('cannot apply temporary directory ACL')
        else:folder.chmod(0o500)
        try:
            try:(folder/'probe').write_bytes(b'x')
            except PermissionError:pass
            else:self.skipTest('current identity can still create in restricted directory')
            self.run_cli(['diff',self.old,self.new,folder/'out'],1);self.assertEqual(list(folder.iterdir()),[])
        finally:
            if os.name=='nt':
                r=subprocess.run(['icacls',str(folder),'/remove:d',user],capture_output=True);self.assertEqual(r.returncode,0)
            else:folder.chmod(0o700)
    def test_patch_output_same_input(self):self.generate();self.run_cli(['patch',self.old,self.patch,self.patch],1)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--exe',type=pathlib.Path,required=True);a=parser.parse_args();EXE=a.exe.resolve()
    if not EXE.is_file():raise SystemExit('CLI executable missing')
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CliFiles))
    private=None
    if result.wasSuccessful():
        r=subprocess.run(['moon','test','cmd/main','--target','native','--deny-warn','--target-dir',str(ROOT/'_build'/('cli-'+platform.system().lower()))],cwd=ROOT,capture_output=True,timeout=120)
        (ROOT/'_build'/('cli-private-'+platform.system()+'.log')).write_bytes(r.stdout+r.stderr)
        if r.returncode or 'Total tests: 9, passed: 9, failed: 0.' not in r.stdout.decode('utf8'):raise SystemExit('Private real-file IO contracts failed; inspect _build/cli-private-'+platform.system()+'.log')
        private=9
    report=dict(platform=platform.platform(),architecture=platform.machine(),python=sys.version,executable=str(EXE),executable_sha256=hashlib.sha256(EXE.read_bytes()).hexdigest(),module_version=version(),tests=result.testsRun,failed=len(result.failures)+len(result.errors),skipped=[dict(case=str(t),reason=reason) for t,reason in result.skipped],cli_invocations=INVOCATIONS,private_real_file_io_tests=private,over_64k_patch=LARGE_PATCH)
    (ROOT/'_build'/('cli-tests-'+platform.system()+'.json')).write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print(json.dumps(report,indent=2))
    if not result.wasSuccessful() or result.testsRun==0:raise SystemExit(1)
