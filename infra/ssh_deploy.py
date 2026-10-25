"""Use the runner's pinned SSH identity to read production or deliver a release."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess


def connection():
    host, user, root = (os.environ[k] for k in ('DEPLOY_HOST', 'DEPLOY_USER', 'DEPLOY_ROOT'))
    if not re.fullmatch(r'[a-zA-Z0-9.-]+', host) or not re.fullmatch(r'[a-z_][a-z0-9_-]*', user):
        raise ValueError('Invalid SSH target')
    if not re.fullmatch(r'/[a-zA-Z0-9/_-]+', root) or '..' in root.split('/'):
        raise ValueError('Invalid persistent root')
    target = user+'@'+host
    return ['ssh', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', target], target, root


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('read', 'deploy'))
    parser.add_argument('--web-only', action='store_true')
    args = parser.parse_args()
    ssh, target, root = connection()
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
