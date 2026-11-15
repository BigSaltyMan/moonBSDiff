"""Only Commit 26 bounded file application: deterministic independent envelopes."""
import argparse,bz2,hashlib,json,pathlib,platform,random,struct,unittest
import test_cli as shared


def integer(n):
    if not -(2**63-1)<=n<=2**63-1:raise ValueError(n)
    return (abs(n) | ((1<<63) if n<0 else 0)).to_bytes(8,'little')


def envelope(streams,size):
    return b'BSDIFF40'+integer(len(streams[0]))+integer(len(streams[1]))+integer(size)+b''.join(streams)


def fixture(size):
    old=bytes(range(256))*20
    triples=[(0,0,1),(0,0,-1)]*90+[(0,0,-3),(4101,4111,-5000),(0,0,2),(4103,size-12315,0)]
    rng=random.Random(20261115026+size)
    delta=rng.randbytes(8204);extra=rng.randbytes(size-8204)
    control=b''.join(integer(v) for t in triples for v in t)
    result=bytearray();pos=0;d=e=0
    for x,y,z in triples:
        result.extend((delta[d+i]+(old[pos+i] if 0<=pos+i<len(old) else 0))%256 for i in range(x));d+=x;pos+=x
        result.extend(extra[e:e+y]);e+=y;pos+=z
    assert len(result)==size and d==len(delta) and e==len(extra)
    streams=[bz2.compress(b,compresslevel=1) for b in [control,delta,extra]]
    return old,bytes(result),streams,len(control)+len(delta)+len(extra),len(triples)


class StreamFiles(unittest.TestCase):
    setUp=shared.CliFiles.setUp
    def run_cli(self,args,code=0):
        result=shared.CliFiles.run_cli(self,args,code)
        self.assertFalse(list(self.p.glob('.moonbsdiff-compat-*')))
        return result

    def put(self,old,streams,size):
        self.old.write_bytes(old);self.patch.write_bytes(envelope(streams,size))

    def test_segmented_restore_and_logical_growth(self):
        for size in [16384,131072]:
            old,new,streams,expanded,controls=fixture(size);self.put(old,streams,size)
            memory=self.p/('memory-'+str(size))
            self.run_cli(['patch','--max-patch-bytes','256KiB',self.old,self.patch,memory])
            self.run_cli(['patch','--stream','--max-patch-bytes','256KiB',self.old,self.patch,self.out])
            self.assertEqual(self.out.read_bytes(),new);self.assertEqual(memory.read_bytes(),new)
            self.assertEqual(self.old.read_bytes(),old)
            self.assertEqual(self.patch.read_bytes(),envelope(streams,size))
            self.out.unlink()
            print(json.dumps(dict(case='segmented-'+str(size),old_bytes=len(old),new_bytes=size,
                                  old_sha256=hashlib.sha256(old).hexdigest(),new_sha256=hashlib.sha256(new).hexdigest(),
                                  patch_bytes=self.patch.stat().st_size,patch_sha256=hashlib.sha256(self.patch.read_bytes()).hexdigest(),
                                  controls=controls,expanded_bytes=expanded,byte_equal=True)))
        # Long final RLE expansion, not retained as an output-sized decoder block.
        new=b'R'*131072
        streams=[bz2.compress(integer(0)+integer(len(new))+integer(0)),bz2.compress(b''),bz2.compress(new)]
        self.put(b'',streams,len(new));self.run_cli(['patch','--stream',self.old,self.patch,self.out])
        self.assertEqual(self.out.read_bytes(),new)

    def test_tail_crc_truncation_and_complete_consumption(self):
        old,new,streams,_,_=fixture(16384)
        rows=[]
        for i in range(3):
            bad=list(streams);v=bytearray(bad[i]);v[-2]^=1;bad[i]=bytes(v);rows.append((bad,'Checksum'))
            bad=list(streams);v=bytearray(bad[i]);v[10]^=1;bad[i]=bytes(v);rows.append((bad,'Checksum'))
            bad=list(streams);bad[i]=bad[i][:-1];rows.append((bad,'Truncated'))
        for suffix in [b'garbage',bz2.compress(b'')]:
            bad=list(streams);bad[2]+=suffix;rows.append((bad,'trailing'))
        rows.append(([bz2.compress(b''),bz2.compress(b''),bz2.compress(b'')+b'x'],'trailing'))
        for streams_bad,expected in rows:
            self.put(old,streams_bad,0 if len(streams_bad[0])<20 else len(new))
            r=self.run_cli(['patch','--stream',self.old,self.patch,self.out],1)
            self.assertIn(expected.lower().encode(),r.stderr.lower());self.assertFalse(self.out.exists())
        self.put(b'',[bz2.compress(b'')]*3,0)
        self.run_cli(['patch','--stream',self.old,self.patch,self.out]);self.assertEqual(self.out.read_bytes(),b'')

    def test_limits_and_failure_recovery(self):
        old,new,streams,expanded,controls=fixture(16384);self.put(old,streams,len(new))
        settings={'--max-old-bytes':len(old),'--max-patch-bytes':self.patch.stat().st_size,'--max-new-bytes':len(new),
                  '--max-output-bytes':len(new),'--max-expanded-bytes':expanded,'--max-controls':controls}
        for name,value in settings.items():
            r=self.run_cli(['patch','--stream',name,str(value-1),self.old,self.patch,self.out],1)
            field={'--max-old-bytes':b'max_old_bytes','--max-patch-bytes':b'max_patch_bytes',
                   '--max-new-bytes':b'max_new_bytes','--max-output-bytes':b'max_output_bytes',
                   '--max-expanded-bytes':b'decompressed_remaining','--max-controls':b'max_control_instructions'}[name]
            self.assertFalse(self.out.exists());self.assertIn(field,r.stderr)
        flags=[str(v) for pair in settings.items() for v in pair]
        self.run_cli(['patch','--stream',*flags,self.old,self.patch,self.out]);self.assertEqual(self.out.read_bytes(),new)

    def test_control_errors_and_unconsumed_data(self):
        cases=[([(0,0,2**63-1),(1,0,0)],b'X',b'',1,'IntegerOverflow'),
               ([(0,0,-(2**63-1)),(1,0,-3)],b'X',b'',1,'IntegerOverflow'),
               ([(2,0,0)],b'XX',b'',1,'OutputOutOfBounds'),
               ([(-1,1,0)],b'',b'X',1,'negative'),
               ([(0,1,0),(0,0,0)],b'',b'X',1,'unconsumed'),
               ([(0,0,0)],b'',b'',0,'unconsumed'),
               ([(1,1,0)],b'XX',b'Y',2,'unconsumed'),
               ([(1,1,0)],b'X',b'YY',2,'unconsumed')]
        for triples,delta,extra,size,message in cases:
            streams=[bz2.compress(b''.join(integer(v) for t in triples for v in t)),bz2.compress(delta),bz2.compress(extra)]
            self.put(b'',streams,size);r=self.run_cli(['patch','--stream',self.old,self.patch,self.out],1)
            self.assertIn(message.encode(),r.stderr);self.assertFalse(self.out.exists())
        self.put(b'',[bz2.compress(b'\x00'*23),bz2.compress(b''),bz2.compress(b'')],1)
        r=self.run_cli(['patch','--stream',self.old,self.patch,self.out],1)
        self.assertIn(b'TruncatedData: control triple',r.stderr);self.assertFalse(self.out.exists())
        # Int64.min is reachable by two legal negative seek controls; no abs(min).
        streams=[bz2.compress(b''.join(integer(v) for t in [(0,0,-(2**63-1)),(0,0,-1),(1,0,0)] for v in t)),bz2.compress(b'X'),bz2.compress(b'')]
        self.put(b'',streams,1);self.run_cli(['patch','--stream',self.old,self.patch,self.out]);self.assertEqual(self.out.read_bytes(),b'X')

    def test_arguments_and_existing_output(self):
        for args in [['diff','--stream'],['verify','--stream'],['inspect','--stream'],
                     ['patch','--stream','--stream'],['patch','--stream','--manifest','no.json'],['patch','--stream','--show-limits']]:
            self.run_cli(args,2)
        old,new,streams,_,_=fixture(16384);self.put(old,streams,len(new));self.out.write_bytes(b'keep')
        self.run_cli(['patch','--stream',self.old,self.patch,self.out],1);self.assertEqual(self.out.read_bytes(),b'keep')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',required=True,type=pathlib.Path);a=p.parse_args()
    shared.EXE=a.exe.resolve()
    if not shared.EXE.is_file():raise SystemExit('CLI executable missing')
    r=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(StreamFiles))
    print(json.dumps(dict(platform=platform.system(),tests=r.testsRun,failed=len(r.errors)+len(r.failures),cli_invocations=shared.INVOCATIONS)))
    if not r.wasSuccessful() or r.testsRun!=5 or r.skipped:raise SystemExit(1)
