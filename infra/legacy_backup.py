"""Fence the known legacy backup scheduler during initial core adoption.

Caller holds the full migration and existing legacy deploy locks. Never kill an
in-flight backup: leave a durable fence and retry after it finishes. Restore only
after legacy services/data have been recovered, before releasing their lock.
"""
import hashlib
from pathlib import Path
import re

import managed_state
import network_bootstrap
import topology
from tunnel_runtime import command

SERVICE = 'voicechat-backup.service'
TIMER = 'voicechat-backup.timer'
DROP_IN = '50-voicechat-core-adoption.conf'


def _templates(root, user):
    source = Path(__file__).parent
    service = (source / SERVICE).read_bytes().replace(b"root='/srv/voicechat'", ("root='" + str(root) + "'").encode())
    if user == 'root': service = service.replace(b'User=voicechat\n', b'User=root\n')
    elif user != 'voicechat': raise ValueError('Unknown legacy backup user')
    return {SERVICE: service, TIMER: (source / TIMER).read_bytes()}


def _show(run, name):
    value = run('systemctl', 'show', name,
        '--property=FragmentPath,DropInPaths,ActiveState,UnitFileState,User,Type')
    return dict(line.split('=', 1) for line in value.splitlines() if '=' in line)


def _verify(directory, root, journal, *, system_root, run):
    units = network_bootstrap.directory(system_root, 'etc/systemd/system')
    drop = network_bootstrap.directory(system_root, 'etc/systemd/system/' + SERVICE + '.d') / DROP_IN
    expected_drop = ('[Unit]\nConditionPathExists=!' + str(directory / 'current.json') + '\n').encode()
    service, timer = _show(run, SERVICE), _show(run, TIMER)
    expected = _templates(root, service.get('User'))
    for name, value in ((SERVICE, service), (TIMER, timer)):
        if value.get('FragmentPath') != str(units / name) or network_bootstrap.existing(units / name) != expected[name]:
            raise ValueError('Unknown legacy backup unit must not be changed')
    if service.get('Type') != 'oneshot' or service.get('UnitFileState') != 'static':
        raise ValueError('Unknown legacy backup service contract')
    actual_drop = network_bootstrap.existing(drop)
    if (actual_drop not in (None, expected_drop) or (actual_drop is not None and journal is None) or
            service.get('DropInPaths', '') not in ('', str(drop)) or timer.get('DropInPaths', '')):
        raise ValueError('Unknown legacy backup drop-in must not be changed')
    if drop.parent.exists() and set(p.name for p in drop.parent.iterdir()) - {DROP_IN}:
        raise ValueError('Unknown legacy backup drop-in directory')
    if timer.get('UnitFileState') not in ('enabled', 'disabled') or timer.get('ActiveState') not in ('active', 'inactive'):
        raise ValueError('Unknown legacy backup timer state')
    hashes = {key: hashlib.sha256(value).hexdigest() for key, value in expected.items()}
    if journal is not None:
        topology.fields(journal, ('schema', 'root', 'units', 'enabled', 'active', 'phase'))
        if (type(journal['schema']) is not int or journal['schema'] != 1 or journal['root'] != str(root) or
                journal['units'] != hashes or type(journal['enabled']) is not bool or type(journal['active']) is not bool or
                journal['phase'] not in ('retiring', 'retired', 'restoring', 'restored')):
            raise ValueError('Resume the same valid legacy backup retirement')
    return service, timer, drop, expected_drop, hashes


def _paths(directory, root, system_root):
    directory, root, system_root = Path(directory).absolute(), Path(root).absolute(), Path(system_root).resolve()
    for path in (directory, root):
        if path.resolve() != path or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(path)):
            raise ValueError('Canonical ASCII backup migration paths required')
    return directory, root, system_root


def retire(directory, root, *, system_root=Path('/'), run=command):
    directory, root, system_root = _paths(directory, root, system_root)
    with managed_state.locked(directory):
        path = directory / 'current.json'
        journal = managed_state.read(path) if path.exists() or path.is_symlink() else None
        service, timer, drop, content, hashes = _verify(directory, root, journal, system_root=system_root, run=run)
        if journal is not None and journal['phase'] in ('restoring', 'restored'):
            raise ValueError('Finish rollback, then use a fresh migration attempt')
        if journal is None:
            if service.get('ActiveState') not in ('inactive', 'failed'):
                raise ValueError('Finish the active legacy backup before starting adoption')
            journal = {'schema': 1, 'root': str(root), 'units': hashes,
                       'enabled': timer['UnitFileState'] == 'enabled', 'active': timer['ActiveState'] == 'active',
                       'phase': 'retiring'}
            managed_state.persist(path, journal)
        network_bootstrap.directory(system_root, drop.parent.relative_to(system_root), create=True)
        if network_bootstrap.existing(drop) is None: network_bootstrap.create_file(drop, content)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'disable', '--now', TIMER)
        # A timer may have fired before its fence was loaded. It must finish
        # naturally after the caller releases the legacy lock; never terminate it.
        service, timer, *_ = _verify(directory, root, journal, system_root=system_root, run=run)
        if service.get('ActiveState') not in ('inactive', 'failed'):
            raise ValueError('Legacy backup is in flight; release its lock and retry after completion')
        if timer['UnitFileState'] != 'disabled' or timer['ActiveState'] != 'inactive':
            raise ValueError('Legacy backup timer did not retire')
        journal = {**journal, 'phase': 'retired'}
        managed_state.persist(path, journal)
        return journal


def restore(directory, root, *, system_root=Path('/'), run=command):
    directory, root, system_root = _paths(directory, root, system_root)
    with managed_state.locked(directory):
        path = directory / 'current.json'; journal = managed_state.read(path)
        _, _, drop, _, _ = _verify(directory, root, journal, system_root=system_root, run=run)
        journal = {**journal, 'phase': 'restoring'}
        managed_state.persist(path, journal)
        if drop.exists(): drop.unlink()
        run('systemctl', 'daemon-reload')
        run('systemctl', 'enable' if journal['enabled'] else 'disable', TIMER)
        run('systemctl', 'start' if journal['active'] else 'stop', TIMER)
        _, timer, *_ = _verify(directory, root, journal, system_root=system_root, run=run)
        if (timer['UnitFileState'] == 'enabled') != journal['enabled'] or (timer['ActiveState'] == 'active') != journal['active']:
            raise ValueError('Legacy backup timer did not restore its original state')
        journal = {**journal, 'phase': 'restored'}
        managed_state.persist(path, journal)
        return journal
