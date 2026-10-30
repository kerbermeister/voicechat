"""Exercise the legacy backup fence on the marked disposable systemd VM only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import legacy_backup
import managed_state


def main():
    base = Path('/srv/voicechat-edge-fixture')
    if sys.platform != 'linux' or os.geteuid() != 0 or base.is_symlink():
        raise ValueError('Use the marked disposable Linux VM')
    key = ' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if json.loads((base / '.disposable-vm').read_text()) != {
            'kind': 'voicechat-disposable-vm', 'ssh_host_key_sha256': hashlib.sha256(key.encode()).hexdigest()}:
        raise ValueError('Disposable VM marker differs from this host')
    def run(*args):
        result = subprocess.run(args, capture_output=True, text=True, timeout=60)
        if result.returncode: raise RuntimeError('Fixture systemd command failed')
        return result.stdout
    units = Path('/etc/systemd/system')
    for name in (legacy_backup.SERVICE, legacy_backup.TIMER):
        if ((units / name).exists() or (units / name).is_symlink() or
                (units / (name + '.d')).exists() or
                run('systemctl','show',name,'--property=LoadState','--value').strip() != 'not-found'):
            raise ValueError('Existing scheduler must not be adopted by a fixture')
    root = Path(tempfile.mkdtemp(prefix='legacy-backup-fixture-', dir=base)); root.chmod(0o700)
    expected = legacy_backup._templates(root, 'root')
    created = []
    stamp = Path('/var/lib/systemd/timers/stamp-' + legacy_backup.TIMER)
    prior_stamp = stamp.exists() or stamp.is_symlink()
    try:
        for name, content in expected.items():
            path = units / name
            with path.open('xb') as output: output.write(content)
            created.append(path)
        run('systemctl','daemon-reload')
        run('systemctl','enable','--now',legacy_backup.TIMER)
        directory = root / 'attempt'
        retired = legacy_backup.retire(directory, root, run=run)
        run('systemctl','start',legacy_backup.SERVICE)
        if run('systemctl','show',legacy_backup.SERVICE,'--property=ConditionResult','--value').strip() != 'no':
            raise AssertionError('Systemd did not enforce the backup fence')
        if run('systemctl','show',legacy_backup.SERVICE,'--property=ExecMainStartTimestampMonotonic','--value').strip() != '0':
            raise AssertionError('Legacy backup executed despite the condition fence')
        if legacy_backup.retire(directory, root, run=run) != retired:
            raise AssertionError('Repeated retirement changed original timer state')
        # Lose the reply after the actual start command during restore.
        def interrupted(*args):
            value = run(*args)
            if args == ('systemctl','start',legacy_backup.TIMER): raise SystemExit('Lost timer response')
            return value
        try: legacy_backup.restore(directory,root,run=interrupted)
        except SystemExit: pass
        else: raise AssertionError('Interrupted restore did not execute')
        if managed_state.read(directory/'current.json')['phase'] != 'restoring':
            raise AssertionError('Restore did not keep its durable intent')
        restored = legacy_backup.restore(directory,root,run=run)
        if restored['phase'] != 'restored' or not restored['enabled'] or not restored['active']:
            raise AssertionError('Original enabled/active timer was not restored')
        run('systemctl','is-enabled','--quiet',legacy_backup.TIMER)
        run('systemctl','is-active','--quiet',legacy_backup.TIMER)
        for name, content in expected.items():
            if (units/name).read_bytes() != content: raise AssertionError('Original backup unit changed')
        result = {'schema':1,'production_changed':False,
            'actual_systemd_condition_prevented_legacy_backup_execution':True,
            'retirement_repeat_preserved_original_enabled_active_state':True,
            'real_timer_restore_lost_response_resumed':True,
            'legacy_unit_source_unchanged':True,
            'limits':['Disposable VM scheduler only; no production adoption or in-flight real backup.']}
    finally:
        run('systemctl','disable','--now',legacy_backup.TIMER)
        # Fixture service must not execute; cleanup never stops a running backup.
        active=run('systemctl','show',legacy_backup.SERVICE,'--property=ActiveState','--value').strip()
        if active not in ('inactive','failed'): raise ValueError('Unexpected running backup must be preserved')
        for path in created:
            if path.read_bytes()!=expected[path.name]: raise ValueError('Modified fixture unit must be preserved')
            path.unlink()
        drop=units/(legacy_backup.SERVICE+'.d')/legacy_backup.DROP_IN
        if drop.exists(): raise ValueError('Finish the fixture fence restore before cleanup')
        if drop.parent.exists(): drop.parent.rmdir()
        run('systemctl','daemon-reload')
        subprocess.run(['systemctl','reset-failed',legacy_backup.SERVICE],capture_output=True)
        if not prior_stamp and (stamp.exists() or stamp.is_symlink()):
            info=stamp.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=0:
                raise ValueError('Unknown timer stamp must be preserved')
            stamp.unlink()
        shutil.rmtree(root)
    result['fixture_units_and_state_removed']=True
    print(json.dumps(result))


if __name__=='__main__':main()
