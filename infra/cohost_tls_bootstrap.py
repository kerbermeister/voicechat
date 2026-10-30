"""Install periodic cohost TLS refresh only after shared public cutover commits."""
import argparse
import os
from pathlib import Path
import re

import cohost_tls
import edge_deploy
import managed_state
import network_bootstrap
import role_bootstrap
import role_deploy
import topology
from tunnel_runtime import command

SERVICE = 'voicechat-cohost-tls.service'
TIMER = 'voicechat-cohost-tls.timer'


def files(record, *, system_root):
    topology.fields(record, ('schema', 'root', 'operator'))
    root = Path(record['root'])
    if (type(record['schema']) is not int or record['schema'] != 1 or root.resolve() != root or
            not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(root))):
        raise ValueError('Canonical cohost TLS scheduler identity required')
    operator = record['operator']
    role_bootstrap.verify_record(system_root, operator)
    if operator['role'] != 'edge' or 'shared_cutover.py' not in operator['files']:
        raise ValueError('Reviewed cohost renewal operator required')
    code = '/opt/voicechat/operators/' + operator['operator_sha256'] + '/infra'
    service = f'''[Unit]
Description=Refresh verified VoiceChat cohost TLS certificates
Requires=docker.service
After=docker.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=oneshot
User=root
Restart=on-failure
RestartSec=30
ExecStart=/usr/bin/python3 {code}/cohost_tls.py --root {root} --refresh
TimeoutStartSec=300
Environment=PYTHONDONTWRITEBYTECODE=1
UMask=0077
'''.encode()
    timer = f'''[Unit]
Description=Periodically refresh VoiceChat cohost certificates from Caddy

[Timer]
OnActiveSec=5min
OnUnitActiveSec=15min
RandomizedDelaySec=60s
Unit={SERVICE}

[Install]
WantedBy=timers.target
'''.encode()
    return {SERVICE: service, TIMER: timer}


def install(root, *, execute=role_deploy.run, run=command, system_root=Path('/')):
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Canonical cohost ingress root required')
    with managed_state.locked(root):
        return _install_locked(root, execute=execute, run=run, system_root=system_root)


def _install_locked(root, *, execute=role_deploy.run, run=command, system_root=Path('/')):
    """Full migration caller may reuse its existing ingress lock."""
    system_root = Path(system_root).resolve()
    target, _, _ = cohost_tls._source(root, execute=execute, system_root=system_root)
    if target['mode'] != 'shared': raise ValueError('Commit public shared ingress before scheduling TLS refresh')
    expected = role_bootstrap.plan(Path(target['edge_root']), 'edge', target['edge_id'])[4]
    if target['operator'] != expected: raise ValueError('Install the reviewed cohost operator before scheduling TLS refresh')
    state = edge_deploy.read_state(Path(target['edge_root']), target['edge_id'])
    if (state['current'] is None or state['pending'] is not None or
            state['current']['manifest']['service_id'] != target['public']['service_id'] or
            state['current']['manifest']['identity'] != {key: target['public'][key] for key in ('canonical_origin','matrix_server_name')}):
        raise ValueError('Committed cohost edge without pending deployment required')
    desired = {'schema': 1, 'root': str(root), 'operator': expected}
    with managed_state.locked(root / 'tls-renewal') as directory:
        current, pending = directory / 'current.json', directory / 'pending.json'
        previous = managed_state.read(current) if current.exists() or current.is_symlink() else None
        journal = {'previous': previous, 'target': desired}
        interrupted = pending.exists() or pending.is_symlink()
        if interrupted:
            journal = managed_state.read(pending)
            topology.fields(journal, ('previous', 'target'))
            if journal['target'] != desired or previous not in (journal['previous'], desired):
                raise ValueError('Resume the same pending cohost TLS timer installation')
        if journal['previous'] is not None and journal['previous'].get('root') != str(root):
            raise ValueError('Existing TLS scheduler belongs to another ingress root')
        before = files(journal['previous'], system_root=system_root) if journal['previous'] is not None else {}
        contents = files(desired, system_root=system_root)
        destinations = {}
        for name, content in contents.items():
            path = network_bootstrap.directory(system_root, 'etc/systemd/system') / name
            actual = network_bootstrap.existing(path)
            if (actual not in (None, before.get(name), content) or
                    (previous is None and actual is not None and not interrupted)):
                raise ValueError('Unclaimed or modified cohost TLS timer unit must be preserved')
            destinations[name] = path
        managed_state.persist(pending, journal)
        network_bootstrap.directory(system_root, 'etc/systemd/system', create=True)
        for name, path in destinations.items():
            actual = network_bootstrap.existing(path)
            if actual is None: network_bootstrap.create_file(path, contents[name])
            elif actual != contents[name]: network_bootstrap.replace_file(path, contents[name])
        run('systemd-analyze', 'verify', '--man=no', *(str(path) for path in destinations.values()))
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable', '--now', TIMER)
        run('systemctl', 'is-enabled', '--quiet', TIMER)
        run('systemctl', 'is-active', '--quiet', TIMER)
        managed_state.persist(current, desired)
        pending.unlink()
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(descriptor)
        finally: os.close(descriptor)
    return desired


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    install(args.root)
    print('Owned cohost TLS refresh timer installed.')


if __name__ == '__main__': main()
