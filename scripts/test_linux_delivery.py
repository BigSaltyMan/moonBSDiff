"""Linux-only real /proc-unavailable validation in a private mount namespace.
No product fault hook, host mount change, old suite or reference program.
"""
import argparse,ctypes,hashlib,json,os,pathlib,platform,pwd,shutil,subprocess,sys,tempfile,uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
def require(ok,what):
    if not ok:raise RuntimeError(what)
def sha(raw):return hashlib.sha256(raw).hexdigest()
def child(a):
    require(os.geteuid()==0,'namespace setup requires root only inside isolated child')
    namespace=os.readlink('/proc/self/ns/mnt');require(namespace!=a.parent_namespace,'mount namespace was not isolated')
    subprocess.run(['mount','-t','tmpfs','-o','mode=0555','none','/proc'],check=True,timeout=15)
    require(not pathlib.Path('/proc/self/fd').exists(),'proc fd namespace is still available')
    libc=ctypes.CDLL(None,use_errno=True)
    require(libc.prctl(38,1,0,0,0)==0,'cannot set no_new_privs')
    os.setgroups([]);os.setgid(a.gid);os.setuid(a.uid)
    class Header(ctypes.Structure):_fields_=[('version',ctypes.c_uint32),('pid',ctypes.c_int)]
    class Caps(ctypes.Structure):_fields_=[('effective',ctypes.c_uint32),('permitted',ctypes.c_uint32),('inheritable',ctypes.c_uint32)]
    caps=(Caps*2)();hdr=Header(0x20080522,0);require(libc.capget(ctypes.byref(hdr),caps)==0,'capget failed')
    require(os.geteuid()==a.uid!=0 and not any(c.effective or c.permitted for c in caps),'CLI must run unprivileged')
    work=pathlib.Path(a.namespace_child);os.chdir(work)
    fd=os.open('.',os.O_TMPFILE|os.O_RDWR,0o600)
    try:
        try:keeper=os.open('/proc/self/fd/'+str(fd),os.O_PATH)
        except OSError as e:proc_errno=e.errno
        else:os.close(keeper);raise RuntimeError('original anonymous/proc path is unexpectedly usable')
    finally:os.close(fd)
    fs=ctypes.create_string_buffer(256);require(libc.statfs(os.fsencode(work),fs)==0,'statfs failed');magic=ctypes.c_long.from_buffer(fs).value
    require(magic==0xef53,'real test requires the supported ext filesystem')
    old=(ROOT/'testdata/manifest/old.bin').read_bytes();new=(ROOT/'testdata/manifest/new.bin').read_bytes()
    pathlib.Path('old.bin').write_bytes(old);pathlib.Path('new.bin').write_bytes(new)
    commands=[['diff','--manifest','update.json','old.bin','new.bin','update.patch'],['patch','--manifest','update.json','old.bin','update.patch','restored.bin'],['verify','--manifest','update.json','old.bin','update.patch']]
    for args in commands:
        r=subprocess.run([a.exe,*args],capture_output=True,timeout=30)
        require(r.returncode==0,'real no-proc CLI failure: '+r.stderr.decode('utf8',errors='replace'))
        require(not r.stderr,'unexpected stderr')
        if args[0]=='verify':require(b'Verification succeeded:' in r.stdout,'missing verification result')
        else:require(not r.stdout,'successful mutation should stay silent')
    require(pathlib.Path('restored.bin').read_bytes()==new,'restored bytes differ')
    require(pathlib.Path('old.bin').read_bytes()==old and pathlib.Path('new.bin').read_bytes()==new,'input mutation')
    require(not list(work.glob('.moonbsdiff-compat-*')),'compatibility objects leaked')
    manifest=json.loads(pathlib.Path('update.json').read_bytes())
    for key,name in [('old','old.bin'),('new','new.bin'),('patch','update.patch')]:
        raw=pathlib.Path(name).read_bytes();require(manifest[key]==dict(size_bytes=str(len(raw)),sha256=sha(raw)),'manifest identity differs')
    report=dict(platform='Linux',kernel=platform.release(),architecture=platform.machine(),filesystem_magic=hex(magic),filesystem='ext4',directory_mode=oct(work.stat().st_mode&0o7777),uid=os.geteuid(),effective_capabilities=0,permitted_capabilities=0,parent_mount_namespace=a.parent_namespace,isolated_mount_namespace=namespace,proc_self_fd_exists=False,anonymous_open_succeeded=True,proc_keeper_errno=proc_errno,product_fault_hook=False,commands=commands,byte_equal=True,files={p:dict(size=pathlib.Path(p).stat().st_size,sha256=sha(pathlib.Path(p).read_bytes())) for p in ['old.bin','new.bin','update.patch','update.json','restored.bin']},private_objects_remaining=0,executable_sha256=sha(pathlib.Path(a.exe).read_bytes()),native_io_sha256=sha((ROOT/'cmd/main/native_io.c').read_bytes()))
    (work/'result.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--exe',required=True);p.add_argument('--uid',type=int);p.add_argument('--gid',type=int);p.add_argument('--namespace-child');p.add_argument('--parent-namespace');a=p.parse_args()
    require(platform.system()=='Linux','Linux-only check')
    a.exe=str(pathlib.Path(a.exe).resolve());require(pathlib.Path(a.exe).is_file(),'CLI executable missing')
    if a.namespace_child:child(a);return
    uid=a.uid if a.uid is not None else os.getuid();require(uid>0,'root coordinator must explicitly select an ordinary --uid')
    gid=a.gid if a.gid is not None else pwd.getpwuid(uid).pw_gid;require(gid>0,'ordinary target gid required')
    work=pathlib.Path(tempfile.mkdtemp(prefix='moonbsdiff-real-no-proc-'))
    if os.geteuid()==0:os.chown(work,uid,gid)
    namespace=os.readlink('/proc/self/ns/mnt');require(pathlib.Path('/proc/self/fd').is_dir(),'host proc baseline unavailable')
    command=([] if os.geteuid()==0 else ['sudo','-n'])+['unshare','--mount','--propagation','private','--',sys.executable,str(pathlib.Path(__file__).resolve()),'--namespace-child',str(work),'--parent-namespace',namespace,'--uid',str(uid),'--gid',str(gid),'--exe',a.exe]
    r=subprocess.run(command,capture_output=True,timeout=120)
    log=ROOT/'_build'/('linux-delivery-isolation-'+uuid.uuid4().hex+'.log');log.parent.mkdir(parents=True,exist_ok=True);log.write_bytes(r.stdout+r.stderr)
    require(os.readlink('/proc/self/ns/mnt')==namespace and pathlib.Path('/proc/self/fd').is_dir(),'host mount state changed')
    require(r.returncode==0,'isolated test failed; see '+str(log))
    report=json.loads((work/'result.json').read_text());report['host_mount_namespace_unchanged']=True
    path=ROOT/'_build'/('linux-delivery-real-'+uuid.uuid4().hex+'.json');path.write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print('REAL LINUX DELIVERY '+json.dumps(dict(report=str(path),uid=report['uid'],filesystem=report['filesystem'],proc_keeper_errno=report['proc_keeper_errno'],byte_equal=report['byte_equal'],commands=len(report['commands']),product_fault_hook=False)))
if __name__=='__main__':main()
