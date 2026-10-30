"""Real package preparation fault drills on an explicitly marked disposable VM.

Use a fresh Debian12 amd64 VM, never a production or previously prepared host.
The runner installs packages globally but keeps its receipts in the marked root.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'infra'))
import host_packages
import managed_state
import node_inventory
import topology


def check(root, inventory):
    root = Path(root).absolute()
    if (os.geteuid() != 0 or root.resolve() != root or root.parent != Path('/srv') or
            not root.name.startswith('voicechat-package-fixture-')):
        raise ValueError('A named owned disposable VM fixture root is required')
    marker = managed_state.read(root / '.disposable-vm')
    topology.fields(marker, ('schema', 'host_key_sha256'))
    host = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if marker != {'schema': 1, 'host_key_sha256': hashlib.sha256(host.encode()).hexdigest()}:
        raise ValueError('Disposable VM marker does not match the actual host')
    node_inventory.validate(inventory)
    if inventory['core']['ssh_host_key'] != host:
        raise ValueError('Fixture inventory does not match this VM')
    state = root / 'state'
    if state.exists() or state.is_symlink():
        raise ValueError('Use a fresh VM/fixture for package installation drills')
    nft_table = 'vc_package_' + uuid.uuid4().hex[:12]
    observed = {}
    dropped = False

    def lose_base_reply(arguments):
        nonlocal dropped
        result = host_packages.command(arguments)
        if not dropped and arguments[:2] == ['apt-get', '-y']:
            dropped = True
            host_packages.command(['nft', 'add', 'table', 'inet', nft_table])
            observed['nft'] = host_packages.command(['nft', '-j', 'list', 'table', 'inet', nft_table])
            raise RuntimeError('Fixture lost reply after real base package installation')
        return result

    try:
        try:
            host_packages.install(state, inventory, 'core', run=lose_base_reply)
        except RuntimeError as error:
            if str(error) != 'Fixture lost reply after real base package installation':
                raise
        else:
            raise AssertionError('Expected lost base installation result')
        assert dropped and managed_state.read(state / 'pending.json')['phase'] == 'base'
        with patch.object(host_packages, 'clear_pending', side_effect=RuntimeError('Fixture lost commit reply')):
            try:
                host_packages.install(state, inventory, 'core')
            except RuntimeError as error:
                if str(error) != 'Fixture lost commit reply':
                    raise
            else:
                raise AssertionError('Expected lost durable commit result')
        assert managed_state.read(state / 'pending.json')['phase'] == 'verify'
        committed = managed_state.read(state / 'current.json')
        process_args = ['systemctl', 'show', 'docker.service', '--property=MainPID',
                        '--property=ExecMainStartTimestampMonotonic']
        before = host_packages.command(process_args)
        calls = []

        def repeat(arguments):
            calls.append(arguments)
            return host_packages.command(arguments)

        assert host_packages.install(state, inventory, 'core', run=repeat) == committed
        assert host_packages.install(state, inventory, 'core', run=repeat) == committed
        assert not any(args[0] in ('apt-get', 'dpkg', 'systemctl') for args in calls)
        assert host_packages.command(process_args) == before
        assert not (state / 'pending.json').exists()
        assert host_packages.command(['nft', '-j', 'list', 'table', 'inet', nft_table]) == observed['nft']
        assert not host_packages.command(['docker', 'ps', '-aq']).strip()
        assert 'wg-vc' not in host_packages.command(['ip', '-j', 'link', 'show'])
        assert ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2]) == host
        evidence = {'schema': 1, 'profile_sha256': committed['profile'],
                    'base': host_packages.BASE, 'docker': host_packages.DOCKER,
                    'actual_clean_host_install': True, 'lost_base_reply_resumed': True,
                    'lost_commit_reply_resumed': True, 'repeat_without_apt_or_service_restart': True,
                    'foreign_nft_table_preserved': True, 'ssh_host_key_preserved': True,
                    'no_application_containers_or_private_tunnel_created': True,
                    'production_changed': False,
                    'limits': ['Disposable Debian12 amd64 VM; dependency preparation only.',
                               'Faults injected after successful apt/base and durable commit, not SIGKILL during dpkg.',
                               'No role deployment, DNS/TLS, host replacement or physical VPS acceptance.']}
    finally:
        if 'nft' in observed:
            actual = host_packages.command(['nft', '-j', 'list', 'table', 'inet', nft_table])
            if actual != observed['nft']:
                raise ValueError('Probe nft table changed; preserve it for inspection')
            host_packages.command(['nft', 'delete', 'table', 'inet', nft_table])
    evidence['probe_nft_table_removed'] = True
    managed_state.persist(root / 'evidence.json', evidence)
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(check(args.root, node_inventory.load(args.inventory))))


if __name__ == '__main__':
    main()
