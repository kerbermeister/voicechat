"""Full initial migration exercise, called by the marked legacy VM harness only.

Real Docker/systemd/SQL/ingress with synthetic account, CA and catalog signing key.
No production credentials, data, certificate keys or signing key are used.
"""
import hashlib
import json
from pathlib import Path
import secrets
import sys
import time
import urllib.parse
import urllib.request

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import cohost_tls_bootstrap
import core_backup_bootstrap
import core_deploy
import edge_deploy
import initial_cohost
import legacy_backup
import managed_state
import network_bootstrap
import role_bootstrap
import role_deploy
import role_release
import route_catalog
import shared_front
from initial_cohost_business import business


def remove_units(expected, timers, *, run):
    units=Path('/etc/systemd/system')
    present={}
    for name,content in expected.items():
        path=units/name;actual=network_bootstrap.existing(path)
        if actual is not None:
            if actual!=content or path.with_name(name+'.d').exists():
                raise ValueError('Modified fixture unit must be preserved')
            present[name]=path
    for name in timers:
        if name in present:run(['systemctl','disable','--now',name])
    # Let an already running consistent backup finish. Never kill its process.
    deadline=time.monotonic()+300
    for name in present:
        if name.endswith('.timer'):continue
        while True:
            state=run(['systemctl','show',name,'--property=ActiveState','--value']).strip()
            if name.startswith('voicechat-core-backup') and state not in (b'inactive',b'failed'):
                if time.monotonic()>=deadline:raise TimeoutError('Fixture backup still active; preserve its state')
                time.sleep(.5);continue
            break
        run(['systemctl','disable','--now',name])
    for path in present.values():path.unlink()
    run(['systemctl','daemon-reload'])


def exercise(old_root,baseline,neighbor,session,*,control_image,web_image,run):
    if Path('/var/lib/voicechat-network').exists():
        raise ValueError('Isolate the original marked VM network before creating legacy resources')
    directory=old_root/'full-fixture';directory.mkdir(mode=0o700)
    root=directory/'managed';edge=root/'edges/a';core=root/'core'
    key=' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    address=json.loads(run(['ip','-j','-4','route','get','198.51.100.10']))[0]['prefsrc']
    public={'schema':1,'service_id':'voicechat','canonical_origin':'https://chat.fixture.invalid',
            'matrix_server_name':'chat.fixture.invalid','web_origins':['https://chat.fixture.invalid'],
            'edges':[{'id':'a','origin':'https://chat.fixture.invalid','turn_host':'turn.fixture.invalid'}]}
    inventory={'schema':1,'service_id':'voicechat','ssh_user':'root','ssh_port':22,
        'core':{'generation':1,'public_ip':address,'tunnel_ip':'10.88.0.1','ssh_host_key':key},
        'edges':[{'id':'a','host':'core','legacy_turn':True,'shared_tls':{
            'network':'vc-initial-cohost-fixture','subnet':'172.30.44.0/29',
            'legacy_ip':'172.30.44.2','ingress_ip':'172.30.44.3'}}]}
    candidate={'schema':1,'commit':'b'*40,'origin':public['canonical_origin'],
               'control':control_image,'web':web_image}
    private=directory/'catalog.pem'
    run(['openssl','genpkey','-algorithm','ED25519','-out',str(private)]);private.chmod(0o600)
    catalog_key=route_catalog.public_key(private);now=int(time.time())
    envelope=json.dumps(route_catalog.sign(public,private,1,now,now+86400)).encode()
    legacy_pointer=(old_root/'current.json').read_bytes()
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    path='/_matrix/client/v3/user/'+urllib.parse.quote(session['user_id'],safe='')+'/account_data/dev.voicechat.full_fixture'
    account_data={'nonce':secrets.token_hex(16)}
    def api(origin,resource,method='GET',body=None):
        request=urllib.request.Request(origin+resource,None if body is None else json.dumps(body).encode(),
            {'Content-Type':'application/json','Authorization':'Bearer '+session['access_token']},method=method)
        with opener.open(request,timeout=20) as response:return json.load(response)
    api('http://127.0.0.1:8088',path,'PUT',account_data)
    units=Path('/etc/systemd/system')
    legacy_units=legacy_backup._templates(old_root,'root')
    planned_names=(*legacy_units,'voicechat-core.service','voicechat-edge-a.service',
        cohost_tls_bootstrap.SERVICE,cohost_tls_bootstrap.TIMER,core_backup_bootstrap.SERVICE,core_backup_bootstrap.TIMER)
    for name in planned_names:
        if (units/name).exists() or (units/name).is_symlink() or (units/(name+'.d')).exists():
            raise ValueError('Existing scheduler/role units must be preserved')
    stamps={name:Path('/var/lib/systemd/timers/stamp-'+name) for name in
            (legacy_backup.TIMER,cohost_tls_bootstrap.TIMER,core_backup_bootstrap.TIMER)}
    prior_stamps={name:path.exists() or path.is_symlink() for name,path in stamps.items()}
    for name,content in legacy_units.items():
        with (units/name).open('xb') as output:output.write(content)
    # The old timer is genuinely enabled/active, with no missed synthetic event.
    if not prior_stamps[legacy_backup.TIMER]:stamps[legacy_backup.TIMER].touch(mode=0o600)
    run(['systemctl','daemon-reload']);run(['systemctl','enable','--now',legacy_backup.TIMER])
    result=None
    try:
        with business(directory,edge,public,inventory,neighbor,run=run) as (shared,execute,ca):
            try:
                print('Full fixture: starting journaled initial migration',file=sys.stderr,flush=True)
                current=initial_cohost.migrate(root,old_root,shared,public,inventory,candidate,envelope,catalog_key,
                    backend_sha256=hashlib.sha256(b'synthetic-full-vm-candidate').hexdigest(),execute=execute,ca_file=ca)
                assert current['data_identity']==baseline['data_identity']
                assert core_deploy.data_identity(core,core_deploy.read_state(core)['current'],execute=execute)==baseline['data_identity']
                assert managed_state.read(root/'initial.json')['phase']=='complete'
                private_origin='http://'+inventory['core']['tunnel_ip']+':8088'
                who=api(private_origin,'/_matrix/client/v3/account/whoami')
                assert who['user_id']==session['user_id'] and who['device_id']==session['device_id']
                assert api(private_origin,path)==account_data
                assert (old_root/'current.json').read_bytes()==legacy_pointer
                for role_root in (core,edge):assert not (role_root/'runtime/full-rollout.json').exists()
                assert initial_cohost.migrate(root,old_root,shared,public,inventory,candidate,envelope,catalog_key,
                    backend_sha256=hashlib.sha256(b'synthetic-full-vm-candidate').hexdigest(),execute=execute,ca_file=ca)==current
                result={'full_initial_cohost_migration_committed':True,'same_target_complete_resume':True,
                    'account_device_account_data_database_and_signing_identity_preserved':True,
                    'legacy_release_pointer_unchanged':True,'production_changed':False,
                    'limits':['Synthetic accounts, CA, catalog key and candidate fingerprint on the marked VM.',
                              'No real device/media acceptance, production transition or full-phase fault drills.']}
            finally:
                expected={}
                for role_root,role,edge_id in ((core,'core',None),(edge,'edge','a')):
                    name,_,_,unit,_=role_bootstrap.plan(role_root,role,edge_id)
                    expected[name]=unit
                # Scheduler files can be derived only after the package exists.
                for location,module in ((shared/'tls-renewal',cohost_tls_bootstrap),(core/'runtime/backup-boot',core_backup_bootstrap)):
                    receipt=location/'current.json';pending=location/'pending.json'
                    record=(managed_state.read(receipt) if receipt.exists() else
                            managed_state.read(pending)['target'] if pending.exists() else None)
                    if record is not None:expected.update(module.files(record,system_root=Path('/')))
                remove_units(expected,(cohost_tls_bootstrap.TIMER,core_backup_bootstrap.TIMER),run=run)
                if (edge/'role.json').exists():
                    manifest=initial_cohost.target_for(root,old_root,shared,public,inventory,candidate,catalog_key,
                        subnet='10.241.0.0/28',backend_sha256=hashlib.sha256(b'synthetic-full-vm-candidate').hexdigest())['edge']
                    record=edge_deploy.record_for(public,inventory,manifest)
                    release=role_deploy.release_path(edge,record)
                    model=json.loads(edge_deploy.compose(edge,record,'config','--format','json',execute=execute))
                    # Validate exact source/images/mounts before removing own apps.
                    initial_cohost.namespace('voicechat-edge-a',[((release/'infra/compose.edge.json',),model)],execute=execute)
                    edge_deploy.compose(edge,record,'down','--volumes',execute=execute)
                if (core/'role.json').exists():
                    manifest=initial_cohost.target_for(root,old_root,shared,public,inventory,candidate,catalog_key,
                        subnet='10.241.0.0/28',backend_sha256=hashlib.sha256(b'synthetic-full-vm-candidate').hexdigest())['core']
                    record=core_deploy.record_for(core,inventory,manifest)
                    # Keep data volumes for the outer legacy fixture cleanup.
                    core_deploy.compose(core,record,'down',execute=execute)
                warm=shared/'front/warm.json'
                if warm.exists():
                    plan=shared/'front/plans'/managed_state.read(warm)['plan']
                    run([*shared_front._command(plan),'down','--remove-orphans'])
    finally:
        # The full attempt owns this exact condition drop-in, if installed.
        journal=root/'initial.json'
        drop=units/(legacy_backup.SERVICE+'.d')/legacy_backup.DROP_IN
        if drop.exists():
            attempt=managed_state.read(journal)['attempt']
            expected=('[Unit]\nConditionPathExists=!'+str(root/('attempt-'+attempt)/'backup/current.json')+'\n').encode()
            if drop.read_bytes()!=expected:raise ValueError('Unknown backup fence must be preserved')
            drop.unlink()
        if drop.parent.exists():
            if any(drop.parent.iterdir()):raise ValueError('Unknown backup drop-in must be preserved')
            drop.parent.rmdir()
        remove_units(legacy_units,(legacy_backup.TIMER,),run=run)
        for name,path in stamps.items():
            if not prior_stamps[name] and path.exists():path.unlink()
    if result is None:raise AssertionError('Full migration did not complete')
    return result
