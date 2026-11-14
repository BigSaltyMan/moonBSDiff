"""Audit a package built from git archive, never from uncommitted worktree files."""
import argparse,hashlib,io,json,pathlib,subprocess,tempfile,zipfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
def sha(raw):return hashlib.sha256(raw).hexdigest()
def require(ok,message):
    if not ok:raise RuntimeError(message)
def audit_zip(path,expected):
    with zipfile.ZipFile(path) as z:
        names=z.namelist()
        require(len(names)==len(set(names)),'duplicate archive member')
        require(z.testzip() is None,'bad ZIP CRC')
        require(set(names)==set(expected),'missing/extra package members')
        for name in names:
            p=pathlib.PurePosixPath(name)
            require(not p.is_absolute() and '..' not in p.parts and '\\' not in name,'unsafe member path')
            require(sha(z.read(name))==expected[name],'changed package member: '+name)
    return len(names)
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--revision',default='HEAD');args=parser.parse_args()
    git=['git','-c','safe.directory='+ROOT.as_posix()]
    revision=subprocess.check_output(git+['rev-parse',args.revision],cwd=ROOT,text=True).strip()
    raw=subprocess.check_output(git+['archive','--format=zip',revision],cwd=ROOT)
    folder=pathlib.Path(tempfile.mkdtemp(prefix='moonbsdiff-release-audit-'));source=folder/'source';source.mkdir()
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        z.extractall(source)
        expected={name:sha(z.read(name)) for name in z.namelist() if not name.endswith('/') and not any(part.startswith('.') for part in pathlib.PurePosixPath(name).parts)}
    commands=[]
    def run(command):
        r=subprocess.run(command,cwd=source,capture_output=True,timeout=180)
        commands.append(dict(command=command,exit_code=r.returncode))
        (folder/('command-'+str(len(commands))+'.log')).write_bytes(r.stdout+r.stderr)
        require(r.returncode==0,'command failed: '+str(command)+'; logs in '+str(folder))
        return r.stdout.decode('utf8')
    version=run(['moon','version','--all'])
    require('moon 0.1.20261102 (ea07287 2026-11-02)' in version and 'moonc v0.10.19+bee578715' in version,'wrong release toolchain')
    run(['moon','update']);run(['moon','fmt','--check']);run(['moon','info'])
    for name,digest in expected.items():
        require(sha((source/name).read_bytes())==digest,'source changed during preparation: '+name)
    run(['moon','package','--list'])
    import re
    module_version=re.search(r'^version\s*=\s*"([^"]+)"', (source/'moon.mod').read_text(encoding='utf8'),re.M)[1]
    package=source/('_build/publish/BigSaltyMan-moonbsdiff-'+module_version+'.zip')
    count=audit_zip(package,expected)
    for name in ['LICENSE','README.md','CHANGELOG.md','moon.mod','moon.pkg','pkg.generated.mbti','internal/bzip2/LICENSE','internal/bzip2/source-lock.json','internal/bzip2/changes.patch','tools/oracle/BSDIFF-LICENSE.txt','tools/oracle/BZIP2-LICENSE.txt','docs/acceptance.md']:
        require(name in expected,'required source/license missing: '+name)
    dependencies={}
    for p in sorted((source/'.mooncakes').glob('*/*/moon.mod')):
        text=p.read_text(encoding='utf8');import re
        name=re.search(r'^name\s*=\s*"([^"]+)"',text,re.M)[1];version_dep=re.search(r'^version\s*=\s*"([^"]+)"',text,re.M)[1]
        license=p.parent/'LICENSE';require(license.is_file(),'dependency license missing')
        dependencies[name]=dict(version=version_dep,manifest_sha256=sha(p.read_bytes()),license_sha256=sha(license.read_bytes()))
    require(dependencies['moonbitstack/moonzip']['version']=='0.3.5','wrong compression version')
    report=dict(schema=1,source_sha=revision,archive_sha256=sha(raw),package_sha256=sha(package.read_bytes()),package_size=package.stat().st_size,members=count,files=expected,dependencies=dependencies,toolchain='\n'.join(line.split(' /')[0] for line in version.splitlines() if line and not line.startswith('Feature flags')),commands=commands,source_directory=str(source),package_path=str(package))
    (folder/'audit.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8')
    print('RELEASE AUDIT '+json.dumps(dict(report= str(folder/'audit.json'),source_sha=revision,package_sha256=report['package_sha256'],members=count)))
if __name__=='__main__':main()
