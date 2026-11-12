import pathlib,sys,tempfile,unittest
from unittest.mock import patch
from check_acceptance import test_summary,current_sha,verify
from conformance_protocol import ConformanceError,run_process
class Gates(unittest.TestCase):
    def test_summary_contract(self):
        self.assertEqual(test_summary('Total tests: 2, passed: 2, failed: 0.\n'),2)
        for bad in ['', 'Total tests: 0, passed: 0, failed: 0.', 'Total tests: 2, passed: 1, failed: 1.']:
            with self.assertRaises(ConformanceError):test_summary(bad)
    def test_failed_child_cannot_fake_success(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ConformanceError):run_process([sys.executable,'-c','print("Total tests: 1, passed: 1, failed: 0.");raise SystemExit(4)'],pathlib.Path(d)/'child')
    def test_missing_or_stale_reference(self):
        with tempfile.TemporaryDirectory() as d:
            folder=pathlib.Path(d)
            with self.assertRaises(FileNotFoundError):verify(folder,'unused','new')
            (folder/'summary.json').write_text('{"run_id":"old"}')
            with self.assertRaises(ConformanceError):verify(folder,'unused','new')
    def test_wrong_checkout(self):
        with patch.dict('os.environ',{'GITHUB_SHA':'0'*40}):
            with self.assertRaises(ConformanceError):current_sha()
if __name__=='__main__':unittest.main()
