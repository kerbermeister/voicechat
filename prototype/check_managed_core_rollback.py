"""Real core/peer rollback proof on the marked disposable Linux VM only.

Uses cached source-built fixture images and synthetic accounts/data. The original
peerless network/key is read, never reconciled or regenerated. Production hosts,
existing core resources, and unowned systemd units are refused before mutation.
"""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from unittest.mock import patch

SOURCE=Path(__file__).resolve().parents[1]
BASE=Path('/srv/voicechat-edge-fixture')
sys.path[:0]=[str(SOURCE/'infra'),str(SOURCE/'prototype')]


def main():
    if sys.platform!='linux' or os.geteuid()!=0 or not BASE.is_dir() or BASE.is_symlink():
        raise ValueError('Use the marked disposable Linux VM as root')
    host=' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if json.loads((BASE/'.disposable-vm').read_text()) != {
            'kind':'voicechat-disposable-vm','ssh_host_key_sha256':hashlib.sha256(host.encode()).hexdigest()}:
        raise ValueError('Disposable VM ownership differs from this host')
    if subprocess.check_output(['systemctl','show','--property=SystemState','--value']).strip()!=b'running':
        raise ValueError('A healthy systemd host is required before creating fixture resources')
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control-image',required=True)
    args=parser.parse_args()
    import core_deploy,initial_cohost,managed_core_rollback,managed_fence,managed_state,role_bootstrap,role_deploy,role_prepare,role_release
    import topology
    assert not subprocess.check_output(['docker','ps','-aq','--filter','label=com.docker.compose.project=voicechat']).strip()
    assert not subprocess.check_output(['docker','volume','ls','-q','--filter','name=^voicechat_']).strip()
    unit=Path('/etc/systemd/system/voicechat-core.service')
    if unit.exists() or unit.is_symlink() or unit.with_name(unit.name+'.d').exists():
        raise ValueError('Existing core boot unit must not be adopted by this fixture')
    subprocess.run(['docker','image','inspect',args.control_image],check=True,stdout=subprocess.DEVNULL)
    network=Path('/var/lib/voicechat-network')
    network_before={name:(network/name).read_bytes() for name in ('desired.json','applied.json')}
    desired=managed_state.read(network/'desired.json');inventory=desired['inventory'];subnet=desired['edge_subnet']
    public=topology.load(SOURCE/'infra/single-vps.example.json');public['service_id']=inventory['service_id']
    volumes_before=set(subprocess.check_output(['docker','volume','ls','-q']).decode().split())
    root=Path(tempfile.mkdtemp(prefix='managed-core-rollback-',dir=BASE));root.chmod(0o700)
    manifests=[role_release.make(public,inventory,'core',digit*40,args.control_image,subnet=subnet) for digit in ('a','b')]
    for manifest in manifests:role_prepare.prepare(root,public,inventory,manifest,subnet)
    values={'LOCAL_STAND':'0','MATRIX_SERVER_NAME':public['matrix_server_name'],
        'PUBLIC_URL':public['canonical_origin'],'PUBLIC_IP':inventory['core']['public_ip'],
        'SMTP_HOST':'smtp.example.com','SMTP_PORT':'587',**{key:secrets.token_hex(32) for key in
        ('POSTGRES_PASSWORD','LIVEKIT_SECRET','POLICY_SECRET','REGISTRATION_SECRET','MACAROON_SECRET','TURN_SECRET')}}
    (root/'runtime/stand.env').write_text(''.join(key+'='+value+'\n' for key,value in values.items()))
    (root/'runtime/stand.env').chmod(0o600)
    role_bootstrap.install(root,'core')
    old,new=manifests;reader=None
    result={'schema':1,'control_image':args.control_image,'production_changed':False}
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    base='http://'+inventory['core']['tunnel_ip']+':8088'
    def api(path,body=None,token=None,method=None):
        data=None if body is None else json.dumps(body).encode()
        headers={'Content-Type':'application/json'}
        if token:headers['Authorization']='Bearer '+token
        with opener.open(urllib.request.Request(base+path,data,headers,method=method),timeout=20) as response:
            return json.load(response)
    def record(manifest):return core_deploy.record_for(root,inventory,manifest)
    def compose(manifest,*arguments):return core_deploy.compose(root,record(manifest),*arguments)
    def policy(manifest):return json.loads(compose(manifest,'run','--rm','--no-deps','-T','--entrypoint','cat','configure','/media/client-policy.json'))
    def set_policy(manifest,value):
        compose(manifest,'stop','synapse','control')
        script="import json,sys;from pathlib import Path;p=Path('/media/client-policy.json');v=json.loads(p.read_text());v['text_max_length']=int(sys.argv[1]);p.write_text(json.dumps(v));p.chmod(0o600)"
        compose(manifest,'run','--rm','--no-deps','-T','--entrypoint','python3','configure','-c',script,str(value))
        core_deploy.start_committed(root,record(manifest));core_deploy.healthy(root,record(manifest))
    def sqlite(manifest,value=None,expected=None):
        script="""import json,sqlite3,sys
from pathlib import Path
p=Path('/work/.prototype/calls');p.mkdir(exist_ok=True)
with sqlite3.connect(p/'calls.sqlite',timeout=10) as db:
 db.execute('CREATE TABLE IF NOT EXISTS managed_rollback_fixture(value TEXT)')
 if sys.argv[1]!='-':db.execute('INSERT INTO managed_rollback_fixture VALUES(?)',(sys.argv[1],))
 rows=[row[0] for row in db.execute('SELECT value FROM managed_rollback_fixture ORDER BY rowid')]
 if sys.argv[2]!='-':assert rows==json.loads(sys.argv[2]),'Post-backup SQLite writes were not preserved'
"""
        compose(manifest,'exec','-T','control','python3','-c',script,value or '-',json.dumps(expected) if expected is not None else '-')
    try:
        print('Stage: initial core',flush=True)
        core_deploy.deploy(root,public,inventory,old,subnet=subnet,activate_monitor=lambda *args:None)
        nonce=api('/_synapse/admin/v1/register')['nonce'];username='managed_rollback_fixture';password=secrets.token_urlsafe(24)
        mac=hmac.new(values['REGISTRATION_SECRET'].encode(),'\0'.join((nonce,username,password,'notadmin')).encode(),hashlib.sha1).hexdigest()
        api('/_synapse/admin/v1/register',{'nonce':nonce,'username':username,'password':password,'admin':False,'mac':mac})
        session=api('/_matrix/client/v3/login',{'type':'m.login.password','user':username,'password':password})
        token=session['access_token'];uid=session['user_id'];device=session['device_id']
        account='/_matrix/client/v3/user/'+urllib.parse.quote(uid,safe='')+'/account_data/voicechat.managed.rollback'
        original_identity=core_deploy.read_state(root)['data_identity']
        def verify(manifest,sentinel,rows):
            who=api('/_matrix/client/v3/account/whoami',token=token)
            assert who['user_id']==uid and who['device_id']==device
            assert api(account,token=token)=={'sentinel':sentinel}
            assert core_deploy.data_identity(root,record(manifest))==original_identity
            sqlite(manifest,expected=rows)
        set_policy(old,12000);original_policy=policy(old)
        sqlite(old,'before-upgrade');api(account,{'sentinel':'before-upgrade'},token,'PUT')
        print('Stage: synthetic data ready; activating monitor',flush=True)
        role_bootstrap.activate(root,'core')
        for cycle,attempt in enumerate(('a'*64,'b'*64),1):
            print('Stage: cycle '+str(cycle)+' claim',flush=True)
            proof=managed_fence.claim(root,public,inventory,old,new,attempt,subnet=subnet)
            assert proof['facts']['manifest']==old and proof['facts']['data_identity']==original_identity
            print('Stage: cycle '+str(cycle)+' apply with consistent backup',flush=True)
            core_deploy.deploy(root,public,inventory,new,subnet=subnet,rollout_attempt=attempt)
            set_policy(new,7000);assert policy(new)['text_max_length']==7000
            stage='after-upgrade-'+str(cycle);sqlite(new,stage);api(account,{'sentinel':stage},token,'PUT')
            print('Stage: cycle '+str(cycle)+' rollback',flush=True)
            managed_fence.retarget(root,public,inventory,old,new,old,attempt)
            if cycle==1:
                image=role_release.json_digest({'image':args.control_image,'root':str(root)})[:12]
                reader=subprocess.check_output(['docker','run','-d','--rm','--network','none','--read-only','--cap-drop','ALL',
                    '--security-opt','no-new-privileges:true','--label','voicechat.fixture='+image,
                    '--volume',str(root/'backups/repository')+':/repository:ro','--entrypoint','python3',
                    'python:3.13-slim-bookworm@sha256:a881a81282cca8c57f97014867fa651def1b3799030cc6b1cff45ed55ba8ef36',
                    '-c','import time;time.sleep(300)']).decode().strip()
                before=(root/'state.json').read_bytes()
                try:managed_core_rollback.rollback(root,public,inventory,old,new,original_identity,attempt,subnet=subnet)
                except ValueError as error:assert 'backup container still uses' in str(error)
                else:raise AssertionError('Active repository reader did not fence rollback')
                assert (root/'state.json').read_bytes()==before
                assert subprocess.check_output(['docker','inspect','--format','{{.State.Running}}',reader]).strip()==b'true'
                core_deploy.healthy(root,record(new))
                subprocess.run(['docker','stop',reader],check=True,capture_output=True);reader=None
                result['active_repository_reader_blocks_rollback_without_kill_or_writer_stop']=True
            if cycle==2:
                persist=managed_state.persist;interrupted=False
                def lost(path,value):
                    nonlocal interrupted
                    persist(path,value)
                    if not interrupted and path==root/'state.json' and value.get('current',{}).get('manifest')==old and value.get('pending') is None:
                        interrupted=True;raise KeyboardInterrupt('Lost response after rollback current commit')
                with patch.object(managed_state,'persist',side_effect=lost):
                    try:managed_core_rollback.rollback(root,public,inventory,old,new,original_identity,attempt,subnet=subnet)
                    except KeyboardInterrupt:pass
                    else:raise AssertionError('Expected committed rollback interruption')
                assert interrupted
                api(account,{'sentinel':'after-lost-commit'},token,'PUT');sqlite(old,'after-lost-commit')
                cfg=compose(old,'ps','-aq','configure').decode().split();assert len(cfg)==1
                configured=subprocess.check_output(['docker','inspect','--format','{{.Id}} {{.State.StartedAt}}',*cfg])
                managed_core_rollback.rollback(root,public,inventory,old,new,original_identity,attempt,subnet=subnet)
                assert subprocess.check_output(['docker','inspect','--format','{{.Id}} {{.State.StartedAt}}',*cfg])==configured
                result['lost_rollback_commit_reply_resumes_without_reconfigure']=True
            else:managed_core_rollback.rollback(root,public,inventory,old,new,original_identity,attempt,subnet=subnet)
            assert policy(old)==original_policy
            expected=['before-upgrade','after-upgrade-1'] if cycle==1 else ['before-upgrade','after-upgrade-1','after-upgrade-2','after-lost-commit']
            verify(old,stage if cycle==1 else 'after-lost-commit',expected)
            observed=managed_fence.observe(root,public,inventory,old,new,old,attempt,subnet=subnet)
            assert observed['facts']['data_identity']==original_identity
            released=managed_fence.release(root,public,inventory,old,new,old,attempt,subnet=subnet)
            assert released['fence'] is None
            assert subprocess.check_output(['systemctl','show','voicechat-core.service','--property=ActiveState','--value']).strip()==b'active'
        result.update(real_core_peer_claim_apply_policy_rollback_release=True,
            post_backup_matrix_and_control_sqlite_writes_preserved=True,
            original_account_device_database_and_signing_identity_preserved=True,
            original_private_policy_restored=True)
    finally:
        if reader is not None:
            subprocess.run(['docker','stop',reader],check=True,capture_output=True)
        print('Stage: owned resource cleanup',flush=True)
        core_deploy.require_backup_idle(root)
        models=[]
        import deploy
        for manifest in manifests:
            release=role_deploy.release_path(root,record(manifest))
            models.append((initial_cohost.configuration_files(deploy.compose_command(release,core=True)),
                           core_deploy.configuration(root,record(manifest))))
        initial_cohost.namespace('voicechat',models,execute=role_deploy.run)
        assert unit.read_bytes()==role_bootstrap.plan(root,'core',None)[3]
        subprocess.run(['systemctl','disable','--now','voicechat-core.service'],check=True,capture_output=True)
        subprocess.run(['systemctl','reset-failed','voicechat-core.service'],check=True,capture_output=True)
        unit.unlink();subprocess.run(['systemctl','daemon-reload'],check=True)
        compose(old,'down','--volumes','--remove-orphans')
        shutil.rmtree(root)
    assert set(subprocess.check_output(['docker','volume','ls','-q']).decode().split())==volumes_before
    assert not subprocess.check_output(['docker','ps','-aq','--filter','label=com.docker.compose.project=voicechat']).strip()
    assert all((network/name).read_bytes()==raw for name,raw in network_before.items())
    subprocess.run(['systemctl','is-active','--quiet','voicechat-network.service'],check=True)
    result.update(fixture_resources_removed=True,original_network_and_key_intent_unchanged=True,
                  controller_sha256=hashlib.sha256((SOURCE/'infra/managed_core_rollback.py').read_bytes()).hexdigest(),
                  limits=['Marked disposable VM, synthetic accounts/policy/data; no production or physical media acceptance.',
                          'Real core/peer operations; distributed journal/SSH/CI integration remains separate.',
                          'Repository-reader fault uses an owned Python container, not a killed Restic process.'])
    (SOURCE/'.prototype').mkdir(mode=0o700,exist_ok=True)
    (SOURCE/'.prototype/managed-core-rollback-evidence.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))


if __name__=='__main__':main()
