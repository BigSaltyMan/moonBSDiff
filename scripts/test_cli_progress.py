"""Commit 27 only: progress protocol, cooperative cancellation and native notification.
Private checkpoint control lives only in a fresh test snapshot; production has no
CLI/environment switch enabling fault injection or checkpoint waits.
"""
import argparse,ctypes,hashlib,json,os,pathlib,platform,queue,shutil,signal,subprocess,sys,tempfile,threading,unittest
from build_cli import ROOT
from test_cli_stream import integer,envelope
import bz2

EXE=PROBE=None
REPORT={'normal_groups':0,'private_cases':[],'real_interrupt':None}


def require(ok,why):
    if not ok:raise RuntimeError(why)


def windows_send(pid):
    kernel=ctypes.WinDLL('kernel32',use_last_error=True)
    # Only the dedicated sender detaches its own inherited console. The test
    # parent and all unrelated processes retain their existing console state.
    kernel.FreeConsole()
    require(kernel.AttachConsole(pid),'sender AttachConsole: '+str(ctypes.get_last_error()))
    try:require(kernel.GenerateConsoleCtrlEvent(1,pid),'sender CTRL_BREAK_EVENT: '+str(ctypes.get_last_error()))
    finally:kernel.FreeConsole()


def snapshot(folder):
    source=folder/'source';source.mkdir()
    for p in ROOT.glob('*.mbt'):
        if not p.name.endswith(('_test.mbt','_wbtest.mbt')):shutil.copy2(p,source/p.name)
    for name in ['moon.mod','moon.pkg']:shutil.copy2(ROOT/name,source/name)
    shutil.copytree(ROOT/'internal',source/'internal',ignore=shutil.ignore_patterns('*_test.mbt','*_wbtest.mbt'))
    shutil.copytree(ROOT/'.mooncakes',source/'.mooncakes')
    cli=source/'cmd/main';cli.mkdir(parents=True)
    identities={}
    for p in (ROOT/'cmd/main').iterdir():
        if p.suffix in ['.mbt','.c','.pkg'] and not p.name.endswith(('_test.mbt','_wbtest.mbt')):
            shutil.copy2(p,cli/p.name);identities[p.name]=hashlib.sha256(p.read_bytes()).hexdigest()
    main=cli/'main.mbt';text=main.read_text(encoding='utf8')
    require(text.count('fn main {')==1,'private snapshot main identity')
    main.write_text(text.replace('fn main {','fn production_main() -> Unit {',1)+'\n'+(ROOT/'scripts/progress_probe.mbt.in').read_text(encoding='utf8'),encoding='utf8',newline='\n')
    result=subprocess.run(['moon','build','cmd/main','--target','native','--release','--deny-warn'],cwd=source,capture_output=True,timeout=180)
    (folder/'build.log').write_bytes(result.stdout+result.stderr)
    require(result.returncode==0,'private probe build failed: '+(result.stdout+result.stderr).decode('utf8',errors='replace'))
    exe=source/'_build/native/release/build/cmd/main/main.exe'
    require(exe.is_file(),'private native executable missing')
    REPORT['probe_sources']=identities
    REPORT['probe_source_transform']='production main renamed; private wrapper appended; other CLI source bytes copied unchanged'
    return exe


def events(raw):
    rows=[json.loads(line) for line in raw.decode('utf8').splitlines()]
    require(bool(rows),'missing JSON events')
    for r in rows:
        require(set(r)=={'schema_version','event','stage','restored_bytes','total_bytes','output_committed','message'},'event fields differ')
        require(r['schema_version']==1 and isinstance(r['output_committed'],bool) and isinstance(r['message'],str),'event types differ')
        require(r['event'] in ['start','phase','progress','complete','cancelled','error'] and
                r['stage'] in ['opening','restoring','validating','delivering','complete'],'unknown event/stage')
        require(isinstance(r['restored_bytes'],str) and r['restored_bytes'].isascii() and r['restored_bytes'].isdigit(),'invalid byte count')
        require(r['total_bytes'] is None or isinstance(r['total_bytes'],str) and r['total_bytes'].isascii() and r['total_bytes'].isdigit(),'invalid total')
    return rows


class Progress(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='moonbsdiff-progress-');self.addCleanup(self.temp.cleanup)
        self.p=pathlib.Path(self.temp.name);self.old=self.p/'old';self.patch=self.p/'patch';self.out=self.p/'out'
        self.expected=b'R'*131072;self.put(self.expected)
    def put(self,expected):
        self.old.write_bytes(b'')
        self.patch.write_bytes(envelope([bz2.compress(integer(0)+integer(len(expected))+integer(0)) if expected else bz2.compress(b''),bz2.compress(b''),bz2.compress(expected)],len(expected)))
    def cli(self,options,code=0):
        r=subprocess.run([str(EXE),'patch','--stream',*options,str(self.old),str(self.patch),str(self.out)],capture_output=True,timeout=30)
        self.assertEqual(r.returncode,code,r.stderr);self.assertEqual(r.stdout,b'');return r
    def check_files(self):
        self.assertEqual(self.old.read_bytes(),b'');self.assertFalse(list(self.p.glob('.moonbsdiff-*')))
    def test_text_and_default(self):
        r=self.cli(['--progress','text']);text=r.stderr.decode()
        for stage in ['start stage=opening','phase stage=restoring','progress stage=restoring','phase stage=validating','phase stage=delivering','complete stage=complete']:self.assertIn(stage,text)
        self.assertLess(text.index('phase stage=delivering'),text.index('complete stage=complete'))
        self.assertEqual(self.out.read_bytes(),self.expected);self.out.unlink()
        self.assertEqual(self.cli([]).stderr,b'');self.check_files()
    def test_json_and_empty(self):
        for raw in [self.expected,b'']:
            self.put(raw);rows=events(self.cli(['--progress','json']).stderr)
            self.assertEqual(rows[0]['event'],'start');self.assertIsNone(rows[0]['total_bytes']);self.assertEqual(rows[-1]['event'],'complete')
            self.assertTrue(rows[-1]['output_committed']);self.assertEqual(rows[-1]['restored_bytes'],str(len(raw)))
            self.assertEqual([r['stage'] for r in rows if r['event']=='phase'],['restoring','validating','delivering'])
            self.assertEqual([r['restored_bytes'] for r in rows if r['event']=='progress'],['65536','131072'] if raw else [])
            self.assertEqual([int(r['restored_bytes']) for r in rows],sorted(int(r['restored_bytes']) for r in rows))
            self.assertTrue(all(not r['output_committed'] for r in rows[:-1]));self.assertEqual(self.out.read_bytes(),raw);self.out.unlink()
        self.check_files()
    def test_structured_runtime_failures(self):
        before=self.patch.read_bytes();self.out.write_bytes(b'keep')
        rows=events(self.cli(['--progress','json'],1).stderr)
        self.assertEqual(rows[-1]['event'],'error');self.assertFalse(rows[-1]['output_committed']);self.assertEqual(self.out.read_bytes(),b'keep');self.out.unlink()
        damaged=bytearray(before);damaged[-2]^=1;self.patch.write_bytes(damaged)
        rows=events(self.cli(['--progress','json'],1).stderr)
        self.assertEqual(rows[-1]['event'],'error');self.assertIn('Checksum',rows[-1]['message']);self.assertNotIn('complete',[r['event'] for r in rows]);self.assertFalse(self.out.exists())
        self.check_files()
    def test_parameter_errors(self):
        for args in [['patch','--stream','--progress'],['patch','--stream','--progress','xml'],['patch','--stream','--progress','json','--progress','text'],['patch','--progress','json'],['diff','--progress','json'],['verify','--progress','text'],['inspect','--progress','json'],['patch','--stream','--progress','json','--manifest','x']]:
            r=subprocess.run([str(EXE),*args],capture_output=True,timeout=20)
            self.assertEqual(r.returncode,2);self.assertEqual(r.stdout,b'');self.assertTrue(r.stderr);self.assertFalse(self.out.exists())


def probe_case(folder,point,fault,real=False):
    with tempfile.TemporaryDirectory(prefix='moonbsdiff-cancel-') as tmp:
        p=pathlib.Path(tmp);old=p/'old';patch=p/'patch';out=p/'out'
        expected=b'R'*8192;old.write_bytes(b'')
        raw=envelope([bz2.compress(integer(0)+integer(len(expected))+integer(0)),bz2.compress(b''),bz2.compress(expected)],len(expected));patch.write_bytes(raw)
        command=[str(PROBE),point,fault,'patch','--stream','--progress','json',str(old),str(patch),str(out)]
        if real:
            kwargs={}
            if os.name=='nt':
                startup=subprocess.STARTUPINFO();startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW;startup.wShowWindow=0
                kwargs=dict(creationflags=subprocess.CREATE_NEW_CONSOLE|subprocess.CREATE_NEW_PROCESS_GROUP,startupinfo=startup)
            child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kwargs)
            q=queue.Queue();threading.Thread(target=lambda:q.put(child.stdout.readline()),daemon=True).start()
            try:
                line=q.get(timeout=25);require(line==('INTERRUPT_READY '+str(child.pid)+'\n').encode() or line==('INTERRUPT_READY '+str(child.pid)+'\r\n').encode(),'missing target readiness: '+repr(line))
                if os.name=='nt':
                    sent=subprocess.run([sys.executable,str(pathlib.Path(__file__).resolve()),'--send-break',str(child.pid)],capture_output=True,timeout=15,creationflags=subprocess.CREATE_NO_WINDOW)
                    require(sent.returncode==0,'isolated Windows sender failed: '+sent.stderr.decode(errors='replace'))
                else:os.kill(child.pid,signal.SIGINT)
                stdout,stderr=child.communicate(timeout=30)
                result=subprocess.CompletedProcess(command,child.returncode,stdout,stderr)
            finally:
                if child.poll() is None:child.kill();child.wait(timeout=10)
        else:result=subprocess.run(command,capture_output=True,timeout=30)
        (folder/(point+'-'+fault+'.stderr')).write_bytes(result.stderr)
        require(result.returncode==0,'private probe exit: '+result.stderr.decode(errors='replace'))
        summary=json.loads(result.stdout);rows=events(result.stderr)
        terminals=[r for r in rows if r['event'] in ['cancelled','error','complete']]
        require(sum(r['event']=='start' for r in rows)==2,'missing/extra operation sequence')
        expect=0 if point=='late' and fault=='none' else 1 if point=='late' else 130
        require(summary==dict(first_code=expect,first_published=expect==0,retry_code=0,retry_published=True),'private outcomes differ: '+repr(summary))
        require([r['event'] for r in terminals]==[('complete' if expect==0 else 'error' if expect==1 else 'cancelled'),'complete'],'wrong terminal sequence')
        require(terminals[0]['output_committed']==(expect==0),'publication state differs')
        if expect==130:
            require(int(terminals[0]['restored_bytes'])==(4096 if point in ['write','wait'] else 8192),'wrong cancellation checkpoint')
            require('Cancellation confirmed' in terminals[0]['message'],'cancellation misclassified')
        if fault=='close':require('close written' in terminals[0]['message'],'cleanup/close warning was swallowed')
        if fault=='race':require(out.read_bytes()==b'other','competing output replaced')
        elif expect==0:require(out.read_bytes()==expected,'committed output differs')
        else:require(not out.exists(),'cancel published an output')
        require((p/'out.retry').read_bytes()==expected,'fresh call after cancel failed')
        require(old.read_bytes()==b'' and patch.read_bytes()==raw,'input changed')
        require(not list(p.glob('.moonbsdiff-*')),'temporary output leaked')
        row=dict(point=point,fault=fault,**summary,temporary_objects=0,byte_equal=True)
        if real:row['notification']='CTRL_BREAK_EVENT sent to private child console group' if os.name=='nt' else 'SIGINT sent to child PID'
        return row


def main():
    global EXE,PROBE
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',type=pathlib.Path);p.add_argument('--send-break',type=int);a=p.parse_args()
    if a.send_break is not None:windows_send(a.send_break);return
    require(a.exe is not None,'--exe required');EXE=a.exe.resolve();require(EXE.is_file(),'CLI missing')
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Progress))
    require(result.wasSuccessful() and result.testsRun==4 and not result.skipped,'new progress contracts failed')
    REPORT.update(platform=platform.system(),normal_groups=result.testsRun,executable_sha256=hashlib.sha256(EXE.read_bytes()).hexdigest())
    folder=pathlib.Path(tempfile.mkdtemp(prefix='p27-',dir=ROOT/'_build'))
    PROBE=snapshot(folder)
    for point,fault in [('write','none'),('write','close'),('gate','race'),('late','none'),('late','race')]:REPORT['private_cases'].append(probe_case(folder,point,fault))
    if os.name!='nt':REPORT['private_cases'].append(probe_case(folder,'pending','none'))
    REPORT['real_interrupt']=probe_case(folder,'wait','none',real=True)
    report=folder/'report.json';report.write_text(json.dumps(REPORT,indent=2)+'\n',encoding='utf8')
    print('FILE PROGRESS '+json.dumps(dict(report=str(report),platform=platform.system(),normal_groups=4,private_cases=len(REPORT['private_cases']),real_interrupt=REPORT['real_interrupt'])))


if __name__=='__main__':main()
