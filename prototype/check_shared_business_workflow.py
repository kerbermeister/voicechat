"""Run the reviewed neighboring workflow hook against disposable shell fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

def check(workflow):
    content = Path(workflow).read_bytes()
    # This probe accepts only the reviewed literal block, not arbitrary YAML or
    # another repository's executable script. No YAML dependency is needed.
    text = content.decode()
    marker = '          script: |\n'
    if text.count(marker) != 1: raise ValueError('One reviewed SSH script block required')
    prefix, _, body = text.partition(marker)
    if '      - name: Deploy over SSH\n' not in prefix or any(line and not line.startswith(' ' * 12) for line in body.splitlines()):
        raise ValueError('Unexpected deployment workflow layout')
    script = '\n'.join(line[12:] for line in body.splitlines()) + '\n'
    expected = '''set -eu
if [ -x /usr/local/sbin/voicechat-shared-deploy ]; then
  /usr/local/sbin/voicechat-shared-deploy avito-update
  exit 0
fi
cd /opt/avito-helper
git diff --quiet
git diff --cached --quiet
git pull --ff-only
cd deploy
docker compose pull
docker compose up -d --remove-orphans
'''
    if script != expected: raise ValueError('Review the changed workflow script before executing the fixture')
    subprocess.run(['/bin/sh', '-n'], input=script.encode(), check=True)
    with tempfile.TemporaryDirectory(prefix='voicechat-workflow-') as temporary:
        root = Path(temporary).resolve()
        repo, tools = root / 'repo', root / 'bin'
        deploy = repo / 'deploy'; deploy.mkdir(parents=True); tools.mkdir()
        trace = root / 'trace'
        manager = root / 'manager'
        env = {**os.environ, 'PATH': str(tools) + ':/usr/bin:/bin', 'VC_FIXTURE_TRACE': str(trace)}
        test_script = script.replace('/usr/local/sbin/voicechat-shared-deploy', str(manager)).replace('/opt/avito-helper', str(repo))
        (tools / 'git').write_text('''#!/bin/sh
if [ "$1" = pull ]; then printf '%s\n' 'git pull' >> "$VC_FIXTURE_TRACE"; exit 0; fi
exec /usr/bin/git -c core.hooksPath=/dev/null "$@"
''')
        (tools / 'docker').write_text('''#!/bin/sh
printf '%s\n' "docker $*" >> "$VC_FIXTURE_TRACE"
''')
        for path in tools.iterdir(): path.chmod(0o755)
        def run():
            return subprocess.run(['/bin/sh', '-c', test_script], env=env, capture_output=True)
        for status in (0, 37):
            manager.write_text('#!/bin/sh\nprintf \'%s\\n\' "manager $*" >> "$VC_FIXTURE_TRACE"\nexit ' + str(status) + '\n')
            manager.chmod(0o755)
            result = run()
            assert result.returncode == status and trace.read_text() == 'manager avito-update\n'
            trace.unlink()
        manager.unlink()
        subprocess.run(['/usr/bin/git', 'init', '-b', 'main', str(repo)], capture_output=True, check=True)
        source = deploy / 'Caddyfile'; source.write_text('reviewed business routes\n')
        subprocess.run(['/usr/bin/git', '-C', str(repo), 'add', '.'], capture_output=True, check=True)
        subprocess.run(['/usr/bin/git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
            '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture'], capture_output=True, check=True)
        source.write_text('custom routes must survive\n')
        result = run()
        assert result.returncode != 0 and source.read_text() == 'custom routes must survive\n' and not trace.exists()
        subprocess.run(['/usr/bin/git', '-C', str(repo), 'add', '.'], capture_output=True, check=True)
        result = run()
        assert result.returncode != 0 and source.read_text() == 'custom routes must survive\n' and not trace.exists()
        subprocess.run(['/usr/bin/git', '-C', str(repo), 'restore', '--staged', '--worktree', 'deploy/Caddyfile'], capture_output=True, check=True)
        result = run()
        assert result.returncode == 0
        assert trace.read_text().splitlines() == ['git pull', 'docker compose pull', 'docker compose up -d --remove-orphans']
    return {'schema': 1, 'workflow_sha256': hashlib.sha256(content).hexdigest(), 'shell_syntax_valid': True,
            'manager_delegation_and_failure_propagation': True, 'dirty_and_staged_custom_routes_preserved_without_manager': True,
            'clean_fallback_preserves_original_deploy_commands': True,
            'limits': ['Disposable shell/Git fixtures; Git fetch and Docker commands stubbed. Actual manager deployment tested separately in VM.']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workflow', type=Path)
    print(json.dumps(check(parser.parse_args().workflow), indent=2))
