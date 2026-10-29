"""Use the runner's pinned SSH identity to read production or deliver a release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

import initial_entry
import release_delivery
import release_source


def connection():
    host, user, root = (os.environ[k] for k in ('DEPLOY_HOST', 'DEPLOY_USER', 'DEPLOY_ROOT'))
    if not re.fullmatch(r'[a-zA-Z0-9.-]+', host) or not re.fullmatch(r'[a-z_][a-z0-9_-]*', user):
        raise ValueError('Invalid SSH target')
    if not re.fullmatch(r'/[a-zA-Z0-9/_-]+', root) or '..' in root.split('/'):
        raise ValueError('Invalid persistent root')
    target = user+'@'+host
    return ['ssh', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', target], target, root



def verify_checkout(files, record, root):
    """Bind public source bytes to the clean Git tree used by this CI build."""
    git=['git','-C',str(root)]
    commit=record['manifest']['commit']
    if subprocess.check_output([*git,'rev-parse','HEAD']).decode().strip()!=commit:
        raise ValueError('Candidate is not the checked-out Git revision')
    if subprocess.run([*git,'diff','--quiet','HEAD','--'],check=False).returncode:
        raise ValueError('Commit reviewed source changes before delivery')
    source={}
    for entry in subprocess.check_output([*git,'ls-tree','-rz','HEAD']).split(b'\0'):
        if not entry:continue
        header,path=entry.split(b'\t',1);name=path.decode()
        if not (name.startswith('infra/') or name in {'prototype/'+value for value in release_delivery.POLICIES}):continue
        mode,kind,checksum=header.decode().split()
        if mode not in ('100644','100755') or kind!='blob':raise ValueError('Only tracked regular deployment sources allowed')
        source[name]=checksum
    if set(files)-{'release.json','backend.sha256'} != source.keys():
        raise ValueError('Source archive differs from the complete tracked deployment file set')
    for name in source:
        expected=subprocess.check_output([*git,'show',commit+':'+name])
        if files[name]!=expected:raise ValueError('Source archive bytes differ from the checked-out Git tree')
    if record['backend']!=release_source.backend_fingerprint(root):
        raise ValueError('Source archive backend fingerprint differs from the Git tree')


def receive(ssh, managed_root, commit, archive, *, checkout=None):
    """Stage only an immutable source package; do not select or run a release."""
    if not re.fullmatch(r'/[a-zA-Z0-9/_-]+',managed_root) or '..' in managed_root.split('/'):
        raise ValueError('Invalid managed root')
    with Path(archive).open('rb') as stream:raw=stream.read(release_delivery.MAX_COMPRESSED+1)
    checksum=hashlib.sha256(raw).hexdigest()
    files,record=release_delivery.unpack(raw,checksum,commit)
    verify_checkout(files,record,Path(checkout) if checkout is not None else Path(__file__).resolve().parents[1])
    bootstrap=files['infra/release_delivery.py']
    command=('umask 077; voicechat_source_dir=$(mktemp -d /tmp/voicechat-source.XXXXXXXXXX) || exit; '
             'cat > "$voicechat_source_dir/receiver.py" || exit; printf "%s\n" "$voicechat_source_dir"')
    temporary=subprocess.check_output([*ssh,command],input=bootstrap).decode().strip()
    if not re.fullmatch(r'/tmp/voicechat-source\.[A-Za-z0-9]{10}',temporary):
        raise ValueError('Unexpected private source bootstrap path')
    receiver=temporary+'/receiver.py'
    try:
        command=['python3','-B',receiver,'--root',managed_root,'--sha256',checksum,'--commit',commit]
        response=json.loads(subprocess.check_output([*ssh,shlex.join(command)],input=raw))
        expected={'schema':1,'path':managed_root+'/bundles/'+checksum,'archive_sha256':checksum}
        if response!=expected:raise ValueError('Immutable receiver returned an unexpected artifact')
        return response
    finally:
        # Only our one public bootstrap file and its unique private directory.
        cleanup=shlex.join(['rm','-f',receiver])+' && '+shlex.join(['rmdir',temporary])
        subprocess.run([*ssh,cleanup],check=True)


def initial(ssh, config, commit, archive, *, checkout=None, retry=False):
    """Run only the verified initial controller, through the same pinned SSH."""
    raw=json.dumps(config,separators=(',',':')).encode()
    initial_entry.request(raw)  # Fail before staging sources on the selected host.
    delivery=receive(ssh,config['root'],commit,archive,checkout=checkout)
    arguments=['python3','-B',delivery['path']+'/infra/initial_entry.py',
               '--root',config['root'],'--source-sha',delivery['archive_sha256']]
    if retry:arguments.append('--retry')
    response=subprocess.check_output([*ssh,shlex.join(arguments)],input=raw)
    # The existing backup emits Restic progress on stdout. Only the final line
    # is the entry point completion record; never echo private progress to CI.
    if len(response)>1024*1024:raise ValueError('Initial controller response is too large')
    value=json.loads(response.rstrip(b'\n').rsplit(b'\n',1)[-1])
    if (set(value)!={'schema','kind','root','commit','target'} or type(value['schema']) is not int or
            value['schema']!=1 or value['kind']!='roles' or value['root']!=config['root'] or
            value['commit']!=commit or not isinstance(value['target'],str) or
            not release_delivery.SHA.fullmatch(value['target'])):
        raise ValueError('Initial controller returned an unexpected completion record; inspect its journal')
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('read', 'deploy', 'receive', 'initial'))
    parser.add_argument('--web-only', action='store_true')
    parser.add_argument('--output',type=Path)
    parser.add_argument('--retry',action='store_true')
    args = parser.parse_args()
    ssh, target, root = connection()
    if args.retry and args.action!='initial':parser.error('Explicit retry applies only to initial migration')
    if args.action == 'initial':
        if args.web_only or args.output is not None:parser.error('Initial deployment does not use web-only or receiver output')
        config=initial_entry.environment()
        if root not in (config['root'],config['legacy_root']):raise ValueError('Deployment root differs from the configured installation')
        result=initial(ssh,config,os.environ['GITHUB_SHA'],Path('/tmp/release.tar.gz'),retry=args.retry)
        print(json.dumps(result));return
    if args.action == 'receive':
        if args.web_only or args.output is None:parser.error('Receive needs --output and does not select a release scope')
        result=receive(ssh,os.environ.get('MANAGED_ROOT',root+'-managed'),os.environ['GITHUB_SHA'],Path('/tmp/release.tar.gz'))
        descriptor=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(descriptor,'w') as output:
            json.dump(result,output);output.write('\n');output.flush();os.fsync(output.fileno())
        return
    if args.action == 'read':
        current = json.loads(subprocess.check_output([*ssh, 'cat '+shlex.quote(root+'/current.json')]))
        if current.get('backend') != Path('backend.sha256').read_text().strip():
            raise SystemExit('Backend sources changed or baseline is missing; run a full deployment first')
        Path('/tmp/current-release.json').write_text(json.dumps(current))
        return
    commit = os.environ['GITHUB_SHA']
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Invalid commit')
    destination = root+'/releases/'+commit
    subprocess.run([*ssh, 'mkdir -p '+shlex.quote(root+'/releases')+' && mkdir '+shlex.quote(destination)], check=True)
    subprocess.run(['scp', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes',
                    '/tmp/release.tar.gz', target+':'+destination+'/release.tar.gz'], check=True)
    command = ('cd '+shlex.quote(destination)+' && tar -xzf release.tar.gz && python3 infra/deploy.py --root '
               +shlex.quote(root)+' --release '+shlex.quote(destination))
    if args.web_only:
        command += ' --web-only'
    subprocess.run([*ssh, command], check=True)


if __name__ == '__main__':
    main()
