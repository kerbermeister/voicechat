"""Install the owned managed-core backup timer after the full migration commits.

The legacy timer/service must already be inactive. This never disables the legacy
scheduler, starts a backup directly, restarts Docker or touches data volumes.
"""
import argparse
import ipaddress
import os
from pathlib import Path
import re

import core_deploy
import managed_state
import network_bootstrap
import node_inventory
import role_bootstrap
import role_deploy
import role_release
import topology
from tunnel_runtime import command

SERVICE = 'voicechat-core-backup.service'
TIMER = 'voicechat-core-backup.timer'


def files(record, *, system_root):
    topology.fields(record, ('schema', 'root', 'operator', 'public', 'inventory', 'edge_subnet'))
    if type(record['schema']) is not int or record['schema'] != 1:
        raise ValueError('Unknown core backup installation schema')
    root = Path(record['root'])
    if root.resolve() != root or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(root)):
        raise ValueError('Canonical ASCII core backup root required')
    public = topology.validate(record['public'])
    node_inventory.validate(record['inventory'], public)
    if not isinstance(record['edge_subnet'], str): raise ValueError('Invalid backup subnet')
    subnet = ipaddress.ip_network(record['edge_subnet'], strict=True)
    if subnet.version != 4 or subnet.prefixlen != 28: raise ValueError('An RFC1918 /28 backup subnet required')
    node_inventory.ipv4(str(subnet.network_address), tunnel=True)
    # Verify historical packages too: an update must recognize the exact old unit.
    if (role_bootstrap.verify_record(system_root, record['operator']) != 'voicechat-core.service' or
            record['operator']['root'] != str(root)):
        raise ValueError('Backup operator belongs to another core')
    code = '/opt/voicechat/operators/' + record['operator']['operator_sha256'] + '/infra'
    directory = root / 'runtime/backup-boot'
    service = f'''[Unit]
Description=Consistent backup of the committed VoiceChat core
Requires=docker.service voicechat-network.service
After=docker.service voicechat-network.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=oneshot
Restart=on-failure
RestartSec=15
ExecStart=/usr/bin/python3 {code}/core_deploy.py --root {root} --topology {directory}/topology.json --inventory {directory}/inventory.json --edge-subnet {record['edge_subnet']} --backup-only
TimeoutStartSec=infinity
Environment=PYTHONDONTWRITEBYTECODE=1
UMask=0077
'''.encode()
    timer = f'''[Unit]
Description=Daily consistent VoiceChat core backup

[Timer]
OnCalendar=*-*-* 03:30:00 UTC
Persistent=true
Unit={SERVICE}

[Install]
WantedBy=timers.target
'''.encode()
    return {SERVICE: service, TIMER: timer}


def install(root, public, inventory, *, subnet='10.241.0.0/28', system_root=Path('/'), run=command):
    root, system_root = Path(root).absolute(), Path(system_root).resolve()
    if root.resolve() != root: raise ValueError('Core backup root must not traverse symlinks')
    with managed_state.locked(root):
        core_deploy.require_no_backup(root)
        role_bootstrap.ready(root, 'core', system_root=system_root, run=run)
        state = core_deploy.read_state(root)
        if state['current'] is None or state['pending'] is not None:
            raise ValueError('A committed core without pending deployment required before scheduling backup')
        if core_deploy.runtime_digest(root) != state['current']['runtime_sha256']:
            raise ValueError('Core runtime changed before backup scheduling')
        role_deploy.release_path(root, state['current'])
        role_release.verify_configuration(state['current']['manifest'], public, inventory)
        for name in ('voicechat-backup.timer', 'voicechat-backup.service'):
            active = run('systemctl', 'show', name, '--property=ActiveState', '--value').strip()
            if active not in ('inactive', 'failed'):
                raise ValueError('Retire the legacy backup timer and finish its service before scheduling core backup')
        operator = managed_state.read(root / 'runtime/boot/current.json')
        target = {'schema': 1, 'root': str(root), 'operator': operator, 'public': public,
                  'inventory': inventory, 'edge_subnet': subnet}
        desired = files(target, system_root=system_root)
        with managed_state.locked(root / 'runtime/backup-boot') as directory:
            current, pending = directory / 'current.json', directory / 'pending.json'
            previous = managed_state.read(current) if current.exists() or current.is_symlink() else None
            journal = {'previous': previous, 'target': target}
            interrupted = pending.exists() or pending.is_symlink()
            if interrupted:
                journal = managed_state.read(pending)
                topology.fields(journal, ('previous', 'target'))
                if journal['target'] != target or previous not in (journal['previous'], target):
                    raise ValueError('Resume the same pending core backup timer installation')
            before = journal['previous']
            prior_files = files(before, system_root=system_root) if before is not None else {}
            destinations = {}
            for name, content in desired.items():
                destination = network_bootstrap.directory(system_root, 'etc/systemd/system') / name
                actual = network_bootstrap.existing(destination)
                if (actual not in (None, prior_files.get(name), content) or
                        (before is None and actual is not None and not interrupted)):
                    raise ValueError('Refusing to replace an unclaimed or modified core backup unit')
                destinations[name] = destination
            for name, key in (('topology.json', 'public'), ('inventory.json', 'inventory')):
                path = directory / name
                if path.exists() or path.is_symlink():
                    actual = managed_state.read(path)
                    if (actual not in ([before[key], target[key]] if before is not None else [target[key]]) or
                            (before is None and not interrupted)):
                        raise ValueError('Unknown core backup configuration must not be overwritten')
            managed_state.persist(pending, journal)
            for name, key in (('topology.json', 'public'), ('inventory.json', 'inventory')):
                managed_state.persist(directory / name, target[key])
            for name, destination in destinations.items():
                network_bootstrap.directory(system_root, 'etc/systemd/system', create=True)
                actual = network_bootstrap.existing(destination)
                if actual is None: network_bootstrap.create_file(destination, desired[name])
                elif actual != desired[name]: network_bootstrap.replace_file(destination, desired[name])
            run('systemd-analyze', 'verify', '--man=no', *(str(path) for path in destinations.values()))
            run('systemctl', 'daemon-reload')
            # This may catch up a missed daily event; only install after the full
            # transition and its public readiness checks have committed.
            run('systemctl', 'enable', '--now', TIMER)
            run('systemctl', 'is-enabled', '--quiet', TIMER)
            run('systemctl', 'is-active', '--quiet', TIMER)
            managed_state.persist(current, target)
            pending.unlink()
            descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(descriptor)
            finally: os.close(descriptor)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('root', 'topology', 'inventory'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    args = parser.parse_args()
    public = topology.load(args.topology)
    install(args.root, public, node_inventory.load(args.inventory, public), subnet=args.edge_subnet)
    print('Managed core backup timer installed; legacy scheduler was not modified.')


if __name__ == '__main__': main()
