"""Opt-in Compose role validation and repeatable core initialization on disposable volumes."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
from render_roles import bundle, write_bundle
from role_config import pinned_image
from test_node_inventory import fixture
from topology import load


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--single-entry', action='store_true')
    args = parser.parse_args()
    public = load(ROOT / ('infra/single-vps.example.json' if args.single_entry else 'infra/three-vps.example.json'))
    inventory = fixture()
    if args.single_entry:
        inventory['edges'] = [{'id':'a','host':'core'}]
    project = 'voicechat-role-' + uuid.uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix=project) as temporary:
        for role in ('core', 'edge'):
            root = Path(temporary) / role
            files, runtime = bundle(public, inventory, role, public['edges'][0]['id'] if role == 'edge' else None)
            write_bundle(root, files, runtime)
            values = {'LOCAL_STAND':'0', 'MATRIX_SERVER_NAME':public['matrix_server_name'],
                      'PUBLIC_URL':public['canonical_origin'], 'PUBLIC_IP':'192.0.2.10',
                      'SMTP_HOST':'smtp.example.com', 'SMTP_PORT':'587',
                      'CONTROL_IMAGE':pinned_image('configure'),
                      'WEB_IMAGE':(ROOT / 'infra/web.Dockerfile').read_text().splitlines()[0].split()[1],
                      'BIND':'127.0.0.1', 'SITE':'chat.example.com', 'HTTP_PORT':'18080', 'HTTPS_PORT':'18443',
                      **{key:secrets.token_hex(32) for key in ('POSTGRES_PASSWORD','LIVEKIT_SECRET','POLICY_SECRET',
                                                             'REGISTRATION_SECRET','MACAROON_SECRET','TURN_SECRET')}}
            if role == 'core':
                for key in ('WEB_IMAGE', 'SITE', 'BIND', 'HTTP_PORT', 'HTTPS_PORT'):
                    values.pop(key)
            env = root / 'infra/runtime/stand.env'
            env.parent.mkdir(exist_ok=True)
            env.write_text(''.join(key + '=' + value + '\n' for key,value in values.items())); env.chmod(0o600)
            command = ['docker','compose','--env-file',str(env),'-f',str(root / 'infra' / ('compose.' + role + '.json'))]
            config = json.loads(subprocess.check_output([*command,'config','--format','json']))
            if role == 'edge':
                assert set(config['services']) == {'configure','web','ingress','turn','route-health'}
                assert set(config['volumes']) == {'turn-config'}
                serialized = json.dumps(config)
                assert all(values[key] not in serialized for key in ('POSTGRES_PASSWORD','LIVEKIT_SECRET','POLICY_SECRET','TURN_SECRET'))
                print('PASS: normalized edge role excludes core services and secrets',flush=True)
                continue
            assert set(config['services']) == {'configure','postgres','synapse','control'}
            for name in ('postgres','synapse','control','media-config'):
                assert config['volumes'][name]['name'] == 'voicechat_' + name
            control = config['services']['control']
            assert not control.get('entrypoint')  # Keep the image's linked SFU/controller supervisor.
            assert all(port.get('host_ip') == '10.88.0.1' for port in control['ports'] if port['target'] in (8090,7880))
            assert all(port.get('host_ip') == inventory['core']['public_ip'] for port in control['ports']
                       if port['target'] not in (8090,7880))
            # Override the project before any mutating command, and verify every volume name.
            command[2:2] = ['-p',project]
            isolated = json.loads(subprocess.check_output([*command,'config','--format','json']))
            assert all(volume['name'].startswith(project + '_') for volume in isolated['volumes'].values())
            try:
                seed = "from pathlib import Path; Path('/matrix/.voicechat-server-name').write_text('chat.example.com'); Path('/matrix/voicechat.signing.key').write_text('test-only-original-identity'); Path('/matrix/media_store').mkdir(exist_ok=True); Path('/matrix/media_store/sentinel').write_text('original-media')"
                subprocess.run([*command,'run','--rm','--no-deps','--entrypoint','python3','configure','-c',seed],check=True)
                for _ in range(2): subprocess.run([*command,'run','--rm','--no-deps','configure'],check=True)
                verify = """from pathlib import Path
import json
assert Path('/proc/sys/net/ipv4/ip_local_reserved_ports').read_text().strip() == '50300-50400'
assert Path('/matrix/voicechat.signing.key').read_text() == 'test-only-original-identity'
assert Path('/matrix/media_store/sentinel').read_text() == 'original-media'
value=json.loads(Path('/matrix/homeserver.yaml').read_text())
assert value['server_name']=='chat.example.com'
assert value['ip_range_whitelist'] == ['10.88.0.1/32']
expected = EXPECTED_TURN
assert value['turn_uris'] == expected
assert not Path('/turn/turnserver.conf').exists()
assert Path('/matrix/homeserver.yaml').stat().st_mode & 0o777 == 0o600
assert Path('/matrix/homeserver.yaml').stat().st_uid == 991
print('PASS: repeated core initialization preserves identity/media, generates TURN list, private config ownership')
"""
                expected = [uri for edge in public['edges'] for uri in (
                    'turn:' + edge['turn_host'] + ':3478?transport=udp',
                    'turn:' + edge['turn_host'] + ':3478?transport=tcp',
                    'turns:' + edge['turn_host'] + ':443?transport=tcp')]
                verify = verify.replace('EXPECTED_TURN', repr(expected))
                subprocess.run([*command,'run','--rm','--no-deps','--entrypoint','python3','configure','-c',verify],check=True)
            finally:
                subprocess.run([*command,'down','--volumes','--remove-orphans'],check=True)
        print('PASS: role Compose validation and isolated core configuration; no production services started',flush=True)


if __name__ == '__main__': main()
