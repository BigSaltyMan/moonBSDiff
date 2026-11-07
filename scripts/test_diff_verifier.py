"""Compact negative checks for the independent parser and export inventory."""
import pathlib,tempfile,unittest
import check_diff as check

class DiffVerifier(unittest.TestCase):
    def fixture(self,name):
        folder=check.ROOT/'testdata/upstream'/name
        return (folder/'patch.bin').read_bytes()

    def test_valid_empty(self):
        self.assertEqual(check.parse(self.fixture('both-empty'),b'',b'')['control_count'],0)

    def test_truncated(self):
        with self.assertRaises((AssertionError,EOFError,OSError)):
            check.parse(self.fixture('both-empty')[:-1],b'',b'')

    def test_trailing_stream_bytes(self):
        with self.assertRaises(AssertionError):
            check.parse(self.fixture('both-empty')+b'!',b'',b'')

    def test_noncanonical_integer(self):
        raw=bytearray(self.fixture('both-empty'));raw[31]=128
        with self.assertRaises(AssertionError):check.parse(bytes(raw),b'',b'')

    def test_wrong_expected_bytes(self):
        with self.assertRaises(AssertionError):check.parse(self.fixture('old-empty'),b'',b'xxxxx')

    def check_log_rejected(self,lines):
        with tempfile.TemporaryDirectory() as directory:
            path=pathlib.Path(directory)/'log.txt';path.write_text(lines)
            with self.assertRaises(AssertionError):check.verify_log(path)

    def test_missing_results(self):self.check_log_rejected('')
    def test_duplicate_results(self):self.check_log_rejected('DIFF:both-empty:00\n'*2)
    def test_unknown_results(self):self.check_log_rejected('DIFF:unknown:00\n')

if __name__=='__main__':unittest.main()
