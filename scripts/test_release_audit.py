import pathlib,tempfile,unittest,zipfile
from release_audit import audit_zip,sha
class AuditTests(unittest.TestCase):
    def test_exact_and_rejected_members(self):
        with tempfile.TemporaryDirectory() as folder:
            p=pathlib.Path(folder)/'source.zip';expected={'a.mbt':sha(b'expected')}
            for mode in ['valid','extra','changed','missing','duplicate']:
                with zipfile.ZipFile(p,'w') as z:
                    if mode!='missing':z.writestr('a.mbt',b'changed' if mode=='changed' else b'expected')
                    if mode=='extra':z.writestr('extra.exe',b'extra')
                    if mode=='duplicate':z.writestr('a.mbt',b'expected')
                if mode=='valid':self.assertEqual(audit_zip(p,expected),1)
                else:
                    with self.assertRaises(RuntimeError):audit_zip(p,expected)
if __name__=='__main__':unittest.main()
