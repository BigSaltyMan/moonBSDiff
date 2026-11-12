"""Commit 17 CLI-only limits contracts; reuse existing file/exit assertions, no old suite."""
import argparse,contextlib,json,pathlib,platform,unittest
import test_cli as shared
from build_cli import ROOT

class CliLimits(unittest.TestCase):
    setUp=shared.CliFiles.setUp
    run_cli=shared.CliFiles.run_cli
    def display(self,operation,*options):
        result=self.run_cli([operation,*options,'--show-limits'])
        return dict(line.split(': ',1) for line in result.stdout.decode('utf8').splitlines())
    def test_effective_display_without_io(self):
        before={p.name:p.read_bytes() for p in self.p.iterdir()}
        defaults=self.display('diff')
        self.assertEqual(defaults,dict(operation='diff',max_old_bytes='65536 bytes',max_new_bytes='65536 bytes',max_output_bytes='65536 bytes (target buffer; patch has separate cap)',max_patch_bytes='131072 bytes',max_decompressed_bytes='262144 bytes (raw control + diff + extra)',max_control_instructions='4096 instructions',max_sort_work='8388608 work units',max_match_work='8388608 work units (matching + generation)'))
        patch=self.display('patch')
        self.assertEqual(patch['max_old_bytes'],'1048576 bytes');self.assertEqual(patch['max_new_bytes'],'1048576 bytes');self.assertEqual(patch['max_patch_bytes'],'131072 bytes')
        self.assertEqual(patch['max_output_bytes'],'1048576 bytes (target buffer; patch has separate cap)');self.assertEqual(patch['max_decompressed_bytes'],'2097152 bytes (cumulative decoded control + diff + extra)');self.assertEqual(patch['max_control_instructions'],'16384 instructions')
        self.assertEqual(patch['max_sort_work'],'unused by patch (no generation budget)');self.assertEqual(patch['max_match_work'],'unused by patch (no generation budget)')
        changed=self.display('diff','--max-old-bytes','256KiB','--max-new-bytes','2147483647B','--max-output-bytes','2MiB','--max-patch-bytes','2047MiB','--max-expanded-bytes','9223372036854775807','--max-controls','9223372036854775807','--max-sort-work','9223372036854775807','--max-match-work','9223372036854775807')
        for field,value in [('max_old_bytes','262144 bytes'),('max_new_bytes','2147483647 bytes'),('max_output_bytes','2097152 bytes (target buffer; patch has separate cap)'),('max_patch_bytes','2146435072 bytes'),('max_decompressed_bytes','9223372036854775807 bytes (raw control + diff + extra)'),('max_control_instructions','9223372036854775807 instructions'),('max_sort_work','9223372036854775807 work units'),('max_match_work','9223372036854775807 work units (matching + generation)')]:self.assertEqual(changed[field],value)
        independent=self.display('diff','--max-old-bytes','256KiB');self.assertEqual(independent['max_new_bytes'],defaults['max_new_bytes']);self.assertEqual(independent['max_sort_work'],defaults['max_sort_work'])
        self.assertEqual(before,{p.name:p.read_bytes() for p in self.p.iterdir()})
    def test_default_and_explicit_roundtrip(self):
        self.run_cli(['diff',self.old,self.new,self.patch]);self.run_cli(['patch',self.old,self.patch,self.out]);self.assertEqual(self.out.read_bytes(),self.new.read_bytes())
        patch=self.p/'explicit.patch';out=self.p/'explicit.out'
        self.run_cli(['diff','--max-old-bytes','5B','--max-new-bytes','6','--max-output-bytes','6B','--max-patch-bytes','1KiB','--max-expanded-bytes','1KiB','--max-controls','4','--max-sort-work','4096','--max-match-work','65536',self.old,self.new,patch])
        self.run_cli(['patch','--max-old-bytes','5','--max-new-bytes','6','--max-output-bytes','6','--max-patch-bytes','1KiB','--max-expanded-bytes','1MiB','--max-controls','4',self.old,patch,out]);self.assertEqual(out.read_bytes(),self.new.read_bytes())
    def test_limits_reach_reader_and_core(self):
        for option,value,field in [('--max-old-bytes','4','max_old_bytes'),('--max-new-bytes','5','max_new_bytes')]:
            with self.subTest(option=option):
                r=self.run_cli(['diff',option,value,self.old,self.new,self.patch],1);self.assertIn(field.encode(),r.stderr);self.assertIn(b'byte limit',r.stderr);self.assertFalse(self.patch.exists())
        for option,value,stage,field in [('--max-sort-work','1','Sorting','sort_remaining'),('--max-match-work','1','Matching','match_remaining'),('--max-output-bytes','5','Header','max_output_bytes')]:
            with self.subTest(option=option):
                r=self.run_cli(['diff',option,value,self.old,self.new,self.patch],1)
                for text in ['kind: ResourceLimitExceeded','stage: '+stage,field,'value: Some(', 'limit: Some(']:self.assertIn(text.encode(),r.stderr)
                self.assertFalse(self.patch.exists())
        self.run_cli(['diff',self.old,self.new,self.patch])
        r=self.run_cli(['patch','--max-patch-bytes',str(self.patch.stat().st_size-1),self.old,self.patch,self.out],1);self.assertIn(b'max_patch_bytes',r.stderr);self.assertIn(b'byte limit',r.stderr);self.assertFalse(self.out.exists())
        r=self.run_cli(['patch','--max-new-bytes','5',self.old,self.patch,self.out],1);self.assertIn(b'max_new_bytes',r.stderr);self.assertIn(b'ResourceLimitExceeded',r.stderr);self.assertFalse(self.out.exists())
        self.run_cli(['patch',self.old,self.patch,self.out]);self.assertEqual(self.out.read_bytes(),self.new.read_bytes())
    def test_reject_arguments_before_io(self):
        rows=[(['diff','--max-old-bytes','0','--show-limits'],'positive'),(['diff','--max-old-bytes','-1','--show-limits'],'ASCII'),(['diff','--max-old-bytes','','--show-limits'],'positive'),(['diff','--max-controls','9223372036854775808','--show-limits'],'overflows'),(['diff','--max-expanded-bytes','9223372036854775807KiB','--show-limits'],'conversion'),(['diff','--max-old-bytes','2048MiB','--show-limits'],'max_old_bytes'),(['diff','--max-old-bytes','1KB','--show-limits'],'ASCII'),(['diff','--max-old-bytes','1kib','--show-limits'],'ASCII'),(['diff','--max-controls','1B','--show-limits'],'without units'),(['diff','--max-old-bytes','1x','--show-limits'],'ASCII'),(['diff','--max-old-bytes=1','--show-limits'],'unknown'),(['diff','--max-old-byte','1','--show-limits'],'unknown'),(['diff','--max-old-bytes','1','--max-old-bytes','2','--show-limits'],'duplicate'),(['diff','--show-limits','--show-limits'],'duplicate'),(['patch','--max-sort-work','1','--show-limits'],'not applicable'),(['patch','--max-match-work','1','--show-limits'],'not applicable'),(['diff','--max-old-bytes'],'missing value'),(['diff','--show-limits',self.old,self.new,self.patch],'no file arguments'),(['diff',self.old,'--max-old-bytes','1'],'precede')]
        for args,fragment in rows:
            with self.subTest(args=args):
                r=self.run_cli(args,2);self.assertIn(fragment.encode(),r.stderr);self.assertFalse(self.patch.exists());self.assertFalse(self.out.exists())
    def test_dash_paths_after_separator(self):
        (self.p/'-old').write_bytes(b'a\x00\xff');(self.p/'-new').write_bytes(b'b\x00\xff!')
        with contextlib.chdir(self.p):
            self.run_cli(['diff','--max-old-bytes','3B','--','-old','-new','-patch']);self.run_cli(['patch','--','-old','-patch','-out'])
        self.assertEqual((self.p/'-out').read_bytes(),(self.p/'-new').read_bytes())

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',required=True,type=pathlib.Path);a=p.parse_args();shared.EXE=a.exe.resolve()
    if not shared.EXE.is_file():raise SystemExit('CLI executable missing')
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CliLimits))
    report=dict(platform=platform.system(),tests=result.testsRun,failed=len(result.errors)+len(result.failures),skipped=len(result.skipped),cli_invocations=shared.INVOCATIONS,scope='Commit 17 only; no old CLI or private IO suite')
    (ROOT/'_build'/('cli-limits-'+platform.system()+'.json')).write_text(json.dumps(report,indent=2)+'\n',encoding='utf8');print(json.dumps(report))
    if not result.wasSuccessful() or not result.testsRun or result.skipped:raise SystemExit(1)
