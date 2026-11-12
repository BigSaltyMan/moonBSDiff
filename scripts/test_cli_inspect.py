"""Commit 18 header-only CLI checks; no diff/apply, decompression or reference tool."""
import argparse,contextlib,json,os,pathlib,platform,unittest
import test_cli as shared
from build_cli import ROOT

def header(control=0,diff=0,new=0):
    def integer(n):return (abs(n) | ((1<<63) if n<0 else 0)).to_bytes(8,'little')
    return b'BSDIFF40'+integer(control)+integer(diff)+integer(new)

def expected(path,size,control,diff,new):
    return dict(schema_version=1,format='BSDIFF40',patch_path=str(path),patch_bytes=str(size),new_bytes=str(new),validation='header-only',compressed_ranges=dict(control=dict(start_bytes='32',length_bytes=str(control)),diff=dict(start_bytes=str(32+control),length_bytes=str(diff)),extra=dict(start_bytes=str(32+control+diff),length_bytes=str(size-32-control-diff))),checks={key:'not-checked' for key in ['compressed_streams','crc','control_instructions','restoration','identity']})

class InspectCli(unittest.TestCase):
    setUp=shared.CliFiles.setUp
    def invoke(self,args,code=0):
        before={p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.p.iterdir()}
        result=shared.CliFiles.run_cli(self,args,code)
        self.assertEqual(before,{p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in self.p.iterdir()})
        return result
    def test_fixed_nonempty_text_and_json(self):
        raw=(ROOT/'testdata/upstream/replace/patch.bin').read_bytes();self.assertEqual(len(raw),134)
        self.assertEqual([int.from_bytes(raw[i:i+8],'little') for i in [8,16,24]],[45,43,20]);self.patch.write_bytes(raw)
        text=self.invoke(['inspect',self.patch]).stdout.decode('utf8').splitlines()
        self.assertEqual(text,['Format: BSDIFF40','Patch bytes: 134','Declared restored bytes: 20','Control compressed range: start=32 length=45 bytes','Diff compressed range: start=77 length=43 bytes','Extra compressed range: start=120 length=14 bytes','Validation: header-only','Compressed streams / CRC: not checked','Control instructions: not checked','Restoration: not checked','Identity: not checked'])
        doc=json.loads(self.invoke(['inspect','--json',self.patch]).stdout)
        self.assertEqual(doc,expected(self.patch,134,45,43,20));self.assertIs(type(doc['schema_version']),int)
    def test_empty_target_and_corrupt_compressed_bytes(self):
        raw=(ROOT/'testdata/upstream/both-empty/patch.bin').read_bytes();self.assertEqual(len(raw),74)
        self.assertEqual([int.from_bytes(raw[i:i+8],'little') for i in [8,16,24]],[14,14,0]);self.patch.write_bytes(raw)
        self.assertEqual(json.loads(self.invoke(['inspect','--json',self.patch]).stdout),expected(self.patch,74,14,14,0))
        raw=(ROOT/'testdata/upstream/replace/patch.bin').read_bytes();self.patch.write_bytes(raw[:32]+bytes(len(raw)-32))
        self.assertEqual(json.loads(self.invoke(['inspect','--json',self.patch]).stdout),expected(self.patch,134,45,43,20))
    def test_int64_precision_and_escaped_paths(self):
        name='-输入 patch.bin' if os.name=='nt' else '-输入 "patch"\n\t\\.bin'
        path=self.p/name;path.write_bytes(header(new=(1<<63)-1))
        with contextlib.chdir(self.p):doc=json.loads(self.invoke(['inspect','--json','--',name]).stdout)
        self.assertEqual(doc,expected(name,32,0,0,(1<<63)-1));self.assertEqual(doc['new_bytes'],'9223372036854775807')
        self.assertTrue(all(isinstance(v,str) for r in doc['compressed_ranges'].values() for v in r.values()))
    def test_format_errors_and_read_cap(self):
        rows=[(bytes(31),'TruncatedData',None,31),(b'BSDIFF43'+bytes(24),'UnsupportedFormat','magic',7),(header(control=-1),'InvalidField','control_length',8),(header(control=1),'TruncatedData','control_length',8),(header(diff=1),'TruncatedData','diff_length',16),(header(new=-1),'InvalidField','new_size',24),(header(control=(1<<63)-1),'IntegerOverflow','control_length',8)]
        for raw,kind,field,offset in rows:
            self.patch.write_bytes(raw)
            with self.subTest(kind=kind,field=field):
                r=self.invoke(['inspect','--json',self.patch],1)
                for fragment in ['kind: '+kind,'stage: Header','offset: Some('+str(offset)+')']:self.assertIn(fragment.encode(),r.stderr)
                if field:self.assertIn(('field: Some("'+field+'")').encode(),r.stderr)
        self.patch.write_bytes((ROOT/'testdata/upstream/replace/patch.bin').read_bytes())
        r=self.invoke(['inspect','--max-patch-bytes','133B','--json',self.patch],1);self.assertIn(b'max_patch_bytes=133 bytes',r.stderr);self.assertIn(b'byte limit 133',r.stderr)
        self.assertEqual(json.loads(self.invoke(['inspect','--max-patch-bytes','134B','--json',self.patch]).stdout),expected(self.patch,134,45,43,20))
        r=self.invoke(['inspect','--json',self.p/'missing'],1);self.assertIn(b'open input',r.stderr)
    def test_argument_errors(self):
        rows=[['inspect'],['inspect','--json','--json','missing'],['inspect','--max-patch-bytes','1','--max-patch-bytes','2','missing'],['inspect','--max-old-bytes','1','missing'],['inspect','--max-sort-work','1','missing'],['inspect','--max-match-work','1','missing'],['inspect','--show-limits'],['inspect','--deep','missing'],['inspect','--max-patch-bytes'],['inspect','--max-patch-bytes','0','missing'],['inspect','--max-patch-bytes','2048MiB','missing'],['inspect','a','--json'],['inspect','a','b'],['diff','--json','a','b','c'],['patch','--json','a','b','c']]
        for args in rows:
            with self.subTest(args=args):self.invoke(args,2)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',required=True,type=pathlib.Path);a=p.parse_args();shared.EXE=a.exe.resolve()
    if not shared.EXE.is_file():raise SystemExit('CLI executable missing')
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(InspectCli))
    report=dict(platform=platform.system(),tests=result.testsRun,failed=len(result.errors)+len(result.failures),skipped=len(result.skipped),cli_invocations=shared.INVOCATIONS,scope='Commit 18 header-only; no diff/apply or old CLI suite')
    (ROOT/'_build'/('cli-inspect-'+platform.system()+'.json')).write_text(json.dumps(report,indent=2)+'\n',encoding='utf8');print(json.dumps(report))
    if not result.wasSuccessful() or not result.testsRun or result.skipped:raise SystemExit(1)
