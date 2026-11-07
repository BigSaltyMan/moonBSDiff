"""Comparator/protocol/process failures are tested without corrupted C inputs."""
import copy,json,pathlib,sys,tempfile,unittest
from conformance_protocol import ConformanceError,validate_rows,parse_moon_log,compare,run_process,read_json

class ComparatorTests(unittest.TestCase):
    def setUp(self):
        self.request={'run_id':'a'*32,'manifest_sha256':'f'*64}
        self.cases={'case':{'old_sha256':'1'*64,'new_sha256':'2'*64}}
        self.rows=[dict(schema=1,run_id='a'*32,manifest_sha256='f'*64,case_id='case',target='native',direction=d,old_sha256='1'*64,new_sha256='2'*64,status='ok',payload_kind='restored',payload_hex=b'NEW'.hex()) for d in ('oracle-to-moon','moon-to-oracle')]
    def validate(self,rows):return validate_rows(rows,self.request,'native',['case'],self.cases)
    def reject(self,mutate):
        rows=copy.deepcopy(self.rows);mutate(rows)
        with self.assertRaises(ConformanceError):self.validate(rows)
    def test_valid_complete_bytes(self):
        result=self.validate(self.rows)
        for raw in result.values():compare(raw,b'NEW')
    def test_same_length_corruption(self):
        with self.assertRaises(ConformanceError):compare(b'NE!',b'NEW')
    def test_truncated_output(self):
        with self.assertRaises(ConformanceError):compare(b'NE',b'NEW')
    def test_missing_result(self):self.reject(lambda rows:rows.pop())
    def test_extra_result(self):self.reject(lambda rows:rows.append(dict(rows[0],case_id='extra')))
    def test_duplicate_identity(self):self.reject(lambda rows:rows.append(rows[0]))
    def test_wrong_target(self):self.reject(lambda rows:rows[0].update(target='js'))
    def test_wrong_direction(self):self.reject(lambda rows:rows[0].update(direction='self-roundtrip'))
    def test_wrong_input_identity(self):self.reject(lambda rows:rows[0].update(old_sha256='0'*64))
    def test_stale_run(self):self.reject(lambda rows:rows[0].update(run_id='b'*32))
    def test_wrong_manifest(self):self.reject(lambda rows:rows[0].update(manifest_sha256='0'*64))
    def test_skip_status(self):self.reject(lambda rows:rows[0].update(status='skipped'))
    def test_unknown_fields(self):self.reject(lambda rows:rows[0].update(extra='ignored'))
    def test_noncanonical_hex(self):self.reject(lambda rows:rows[0].update(payload_hex='4e 45 57'))
    def test_schema_boolean(self):self.reject(lambda rows:rows[0].update(schema=True))
    def test_json_duplicate_keys(self):
        with self.assertRaises(ConformanceError):read_json('{"schema":1,"schema":1}')
    def test_stdout_strictness(self):
        rows=copy.deepcopy(self.rows);rows[1]['payload_kind']='patch'
        text=''.join('CONFORMANCE:'+json.dumps(row)+'\n' for row in rows)+'Total tests: 1, passed: 1, failed: 0.\n'
        parse_moon_log(text,self.request,'native',['case'],self.cases)
        for bad in [text+'unexpected\n',text.replace('Total tests: 1','Total tests: 0'),text.split('Total tests:')[0]]:
            with self.assertRaises(ConformanceError):parse_moon_log(bad,self.request,'native',['case'],self.cases)

class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.work=pathlib.Path(self.temp.name)
    def test_nonzero(self):
        with self.assertRaises(ConformanceError) as error:run_process([sys.executable,'-c','raise SystemExit(7)'],self.work/'process')
        self.assertEqual(error.exception.kind,'process')
    def test_timeout(self):
        with self.assertRaises(ConformanceError) as error:run_process([sys.executable,'-c','import time;time.sleep(5)'],self.work/'process',timeout=0.1)
        self.assertEqual(error.exception.kind,'timeout')
    def test_stale_output_even_with_correct_bytes(self):
        output=self.work/'output';output.write_bytes(b'NEW')
        with self.assertRaises(ConformanceError) as error:run_process([sys.executable,'-c','pass'],self.work/'process',output=output)
        self.assertEqual(error.exception.kind,'stale-output')
    def test_missing_output(self):
        with self.assertRaises(ConformanceError):run_process([sys.executable,'-c','pass'],self.work/'process',output=self.work/'output')
    def test_fresh_success(self):
        output=self.work/'output'
        run_process([sys.executable,'-c','import pathlib,sys;pathlib.Path(sys.argv[1]).write_bytes(b"NEW")',output],self.work/'process',output=output)
        compare(output.read_bytes(),b'NEW')

if __name__=='__main__':unittest.main()
