"""External candidate or registry consumer with a fresh SDK registry and project."""
import argparse,json,os,pathlib,shutil,subprocess,tempfile,urllib.request,zipfile
from release_audit import audit_zip,require,sha
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--candidate',type=pathlib.Path);p.add_argument('--audit',required=True,type=pathlib.Path);p.add_argument('--targets',nargs='+',choices=['native','js','wasm-gc'],default=['js','wasm-gc']);a=p.parse_args()
    audit=json.loads(a.audit.read_text(encoding='utf8'));folder=pathlib.Path(tempfile.mkdtemp(prefix='moonbsdiff-consumer-'));sdk=folder/'sdk';sdk.mkdir()
    original=pathlib.Path(os.environ['MOON_HOME']).resolve() if os.environ.get('MOON_HOME') else pathlib.Path(shutil.which('moon')).resolve().parent.parent
    for name in ['bin','include','lib','share']:shutil.copytree(original/name,sdk/name)
    env=dict(os.environ,MOON_HOME=str(sdk),PATH=str(sdk/'bin')+os.pathsep+os.environ['PATH']);project=folder/'consumer';project.mkdir()
    commands=[]
    def run(command,cwd=project):
        r=subprocess.run(command,cwd=cwd,env=env,capture_output=True,timeout=240)
        (folder/('command-'+str(len(commands))+'.log')).write_bytes(r.stdout+r.stderr)
        commands.append(dict(command=command,exit_code=r.returncode))
        require(r.returncode==0,'consumer command failed: '+str(command)+'; logs '+str(folder))
        return r.stdout.decode('utf8')
    version=run(['moon','version','--all']);require('moonc v0.10.19+bee578715' in version,'wrong consumer compiler')
    (project/'moon.mod').write_text('name = "releasecheck/consumer"\nversion = "0.1.0"\n',encoding='utf8')
    (project/'moon.pkg').write_bytes((ROOT/'cmd/example/moon.pkg').read_bytes())
    (project/'main.mbt').write_bytes((ROOT/'cmd/example/main.mbt').read_bytes())
    mode='candidate' if a.candidate else 'registry'
    if a.candidate:
        audit_zip(a.candidate,audit['files'])
        dependency=folder/'candidate';dependency.mkdir()
        with zipfile.ZipFile(a.candidate) as z:z.extractall(dependency)
        (folder/'moon.work').write_text('members = ["candidate", "consumer"]\n',encoding='utf8')
        with (project/'moon.mod').open('a',encoding='utf8') as f:f.write('import { "BigSaltyMan/moonbsdiff@0.1.0" }\n')
        run(['moon','update'])
        package=a.candidate.read_bytes()
    else:
        # No workspace, path override, copied dependency or prepopulated registry.
        require(not (folder/'moon.work').exists(),'registry workspace override')
        run(['moon','update']);run(['moon','add','BigSaltyMan/moonbsdiff@0.1.0'])
        url='https://download.mooncakes.io/user/BigSaltyMan/moonbsdiff/0.1.0.zip'
        with urllib.request.urlopen(url,timeout=60) as response:package=response.read()
        downloaded=folder/'registry.zip';downloaded.write_bytes(package);audit_zip(downloaded,audit['files'])
        dependency=project/'.mooncakes/BigSaltyMan/moonbsdiff'
        require(dependency.is_dir(),'installed registry dependency missing')
        for name,digest in audit['files'].items():require((dependency/name).is_file() and sha((dependency/name).read_bytes())==digest,'installed registry bytes differ: '+name)
    for target in a.targets:
        run(['moon','check','--target',target,'--deny-warn']);run(['moon','build','--target',target])
        output=run(['moon','run','.','--target',target])
        require('restored bytes equal predefined new bytes: PASS' in output,'consumer success marker missing')
    tree=run(['moon','tree'])
    report=dict(schema=1,mode=mode,source_sha=audit['source_sha'],package_sha256=sha(package),package_size=len(package),candidate_sha256=audit['package_sha256'],member_bytes_equal=True,targets=a.targets,byte_equal=True,toolchain='\n'.join(line.split(' /')[0] for line in version.splitlines() if line and not line.startswith('Feature flags')),dependency_tree=tree,commands=commands)
    (folder/'consumer.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf8');print('CONSUMER PASS '+json.dumps(dict(report=str(folder/'consumer.json'),mode=mode,targets=a.targets,package_sha256=sha(package))))
if __name__=='__main__':main()
