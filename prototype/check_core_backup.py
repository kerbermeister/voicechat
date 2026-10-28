"""Real core backup/check/restore on disposable Docker volumes and synthetic data.

This starts a uniquely named PostgreSQL fixture, never production writers, and
removes its containers/network/volumes after the probe. It pulls pinned public
images and writes only a public evidence record under .prototype.
"""
import hashlib, json, os, sqlite3, subprocess, sys, tempfile, uuid
from pathlib import Path

def main():
    source = Path(__file__).resolve().parents[1]
    sys.path[:0] = [str(source / 'infra'), str(source / 'prototype')]
    import deploy
    from render_roles import bundle, write_bundle
    from role_config import pinned_image
    from test_node_inventory import fixture
    from topology import load
    name = 'vc-core-backup-' + uuid.uuid4().hex[:10]

    def run(args, **kw):
        return subprocess.run(args, check=True, capture_output=True, timeout=240, **kw)
    public = load(source / 'infra/single-vps.example.json')
    inventory = fixture()
    inventory['edges'] = [{'id': 'a', 'host': 'core'}]
    with tempfile.TemporaryDirectory(prefix=name + '-') as temp:
        root = Path(temp)
        (root / 'runtime').mkdir(mode=448)
        (root / 'releases').mkdir()
        release = root / 'releases' / 'fixture'
        files, runtime = bundle(public, inventory, 'core')
        write_bundle(release, files, runtime)
        (release / 'infra/runtime').rmdir()
        (release / 'infra/runtime').symlink_to(root / 'runtime')
        values = {'LOCAL_STAND': '0', 'MATRIX_SERVER_NAME': public['matrix_server_name'], 'PUBLIC_URL': public['canonical_origin'], 'PUBLIC_IP': '192.0.2.10', 'SMTP_HOST': 'smtp.example.com', 'SMTP_PORT': '587', **{key: 'synthetic-fixture-only' for key in ('POSTGRES_PASSWORD', 'LIVEKIT_SECRET', 'POLICY_SECRET', 'REGISTRATION_SECRET', 'MACAROON_SECRET', 'TURN_SECRET')}}
        (root / 'runtime/stand.env').write_text(''.join((k + '=' + v + '\n' for k, v in values.items())))
        (root / 'runtime/stand.env').chmod(384)
        state = {'schema': 1, 'fixture': 'core-backup-synthetic'}
        (root / 'state.json').write_text(json.dumps(state))
        (root / 'state.json').chmod(384)
        env = {**os.environ, 'COMPOSE_PROJECT_NAME': name, 'CONTROL_IMAGE': pinned_image('configure'), 'COMPOSE_DISABLE_ENV_FILE': 'true'}

        def compose(*args, **kwargs):
            return run(deploy.compose_command(release, *args, core=True), env=env, **kwargs)
        config = json.loads(compose('config', '--format', 'json').stdout)
        assert all((value['name'].startswith(name + '_') for value in config['volumes'].values()))
        try:
            run(['docker', 'pull', deploy.RESTIC])
            compose('up', '-d', '--wait', '--wait-timeout', '180', 'postgres')
            compose('exec', '-T', 'postgres', 'psql', '-U', 'synapse', '-d', 'synapse', '-v', 'ON_ERROR_STOP=1', '-c', "CREATE TABLE backup_fixture(value TEXT); INSERT INTO backup_fixture VALUES ('preserve-synthetic-data');")
            seed = "from pathlib import Path; Path('/matrix/.voicechat-server-name').write_text('chat.example.com'); Path('/matrix/voicechat.signing.key').write_text('synthetic-preserved-key'); Path('/matrix/media_store').mkdir(exist_ok=True); Path('/matrix/media_store/sentinel').write_text('synthetic-media')"
            compose('run', '--rm', '--no-deps', '--entrypoint', 'python3', 'configure', '-c', seed)
            compose('run', '--rm', '--no-deps', 'configure')
            control = config['volumes']['control']['name']
            run(['docker', 'run', '--rm', '--network', 'none', '-v', control + ':/data', '--entrypoint', 'python3', pinned_image('configure'), '-c', 'import sqlite3; db=sqlite3.connect(\'/data/probe.sqlite\'); db.execute(\'CREATE TABLE fixture(value TEXT)\'); db.execute("INSERT INTO fixture VALUES (\'synthetic-control-data\')"); db.commit()'])
            deploy.backup(root, release, env, core=True)
            restore = root / 'restore'
            restore.mkdir()
            run(['docker', 'run', '--rm', '--network', 'none', '-e', 'RESTIC_PASSWORD_FILE=/password', '-v', str(root / 'runtime/backup-password') + ':/password:ro', '-v', str(root / 'backups/repository') + ':/repository', '-v', str(restore) + ':/restore', deploy.RESTIC, '-r', '/repository', 'restore', 'latest', '--target', '/restore'])
            snapshot = restore / 'snapshot'
            assert (snapshot / 'synapse/voicechat.signing.key').read_text() == 'synthetic-preserved-key'
            assert (snapshot / 'synapse/media_store/sentinel').read_text() == 'synthetic-media'
            with sqlite3.connect(snapshot / 'control/probe.sqlite') as db:
                assert db.execute('SELECT value FROM fixture').fetchall() == [('synthetic-control-data',)]
            assert json.loads((snapshot / 'state.json').read_text()) == state
            assert (snapshot / 'runtime/stand.env').read_bytes() == (root / 'runtime/stand.env').read_bytes()
            assert not list(snapshot.rglob('backup-password'))
            listing = compose('exec', '-T', 'postgres', 'pg_restore', '--list', input=(snapshot / 'database/postgres.dump').read_bytes()).stdout
            assert b'backup_fixture' in listing
            evidence = {'schema': 1, 'real_restic_backup_check_restore': True, 'postgres_dump_contains_fixture_table': True, 'matrix_key_and_media_preserved': True, 'control_sqlite_preserved': True, 'core_role_state_and_runtime_saved': True, 'backup_password_excluded': True, 'restic_image': deploy.RESTIC, 'limits': ['Synthetic isolated core volumes; no production data or full application restore.', 'Writers were never started in this fixture; rollout must enforce stop/backup ordering.']}
        finally:
            compose('down', '--volumes', '--remove-orphans')
    assert not run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + name]).stdout.strip()
    assert not run(['docker', 'volume', 'ls', '-q', '--filter', 'name=' + name]).stdout.strip()
    assert not run(['docker', 'network', 'ls', '-q', '--filter', 'name=' + name]).stdout.strip()
    evidence['fixture_resources_removed'] = True
    evidence['source_sha256'] = hashlib.sha256((source / 'infra/deploy.py').read_bytes()).hexdigest()
    (source / '.prototype').mkdir(mode=448, exist_ok=True)
    (source / '.prototype/core-backup-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))
if __name__ == '__main__':
    main()
