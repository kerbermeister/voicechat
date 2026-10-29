"""Full initial migration exercise, called by the marked legacy VM harness only.

Real Docker/systemd/SQL/ingress with synthetic account, CA and catalog signing key.
No production credentials, data, certificate keys or signing key are used.
"""
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import tempfile
import sys
import time
import urllib.parse
import urllib.request
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import cohost_tls_bootstrap
import core_backup_bootstrap
import core_deploy
import edge_deploy
import initial_cohost
import initial_entry
import legacy_backup
import managed_state
import managed_release
import network_bootstrap
import role_bootstrap
import role_deploy
import role_release
import route_catalog
import shared_front
import shared_cutover
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
        if run(['systemctl','show',name,'--property=ActiveState','--value']).strip()==b'failed':
            run(['systemctl','reset-failed',name])
    for path in present.values():path.unlink()
    run(['systemctl','daemon-reload'])



def cleanup_role(root,public,inventory,initial,*,run):
    role,identifier=initial['role'],initial['edge_id']
    module=core_deploy if role=='core' else edge_deploy
    state=module.read_state(root) if role=='core' else module.read_state(root,identifier)
    original=(core_deploy.record_for(root,inventory,initial) if role=='core' else
              edge_deploy.record_for(public,inventory,initial))
    records=[original,*[state[key] for key in ('current','previous') if state[key] is not None]]
    if state['pending'] is not None:records.append(state['pending']['target'])
    models=[];seen=set()
    for record in records:
        role_release.verify_configuration(record['manifest'],public,inventory)
        checksum=role_release.json_digest(record['manifest'])
        if checksum in seen:continue
        seen.add(checksum);release=role_deploy.release_path(root,record)
        model=json.loads(module.compose(root,record,'config','--format','json',execute=run))
        models.append((((release/('infra/compose.'+role+'.json')),),model))
    initial_cohost.namespace('voicechat' if role=='core' else 'voicechat-edge-'+identifier,models,execute=run)
    record=state['current'] or original
    # Core data belongs to the outer legacy fixture and is removed there.
    module.compose(root,record,'down',*(['--volumes'] if role=='edge' else []),execute=run)


def fenced_stop(core, edge, *, run, roles=('core','edge')):
    snapshots = {}
    for root, role, edge_id in ((core,'core',None),(edge,'edge','a')):
        if role not in roles:continue
        state = core_deploy.read_state(root) if role == 'core' else edge_deploy.read_state(root,edge_id)
        if state['current'] is None: continue
        record = state['current']
        compose = core_deploy.compose if role == 'core' else edge_deploy.compose
        configuration = compose(root,record,'ps','-a','-q','configure',execute=run).decode().strip()
        if not configuration: raise AssertionError('Missing committed configure container')
        snapshots[str(root)] = run(['docker','inspect','--format',
            '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}',configuration])
        services = ['postgres','synapse','control'] if role == 'core' else ['route-health','web','turn']
        compose(root,record,'stop',*services,execute=run)
        identifiers = compose(root,record,'ps','-a','-q',*services,execute=run).decode().split()
        if not identifiers: raise AssertionError('Missing stopped committed roles')
        role_bootstrap.ready(root,role,edge_id)
        if initial_cohost.role_deploy.pending_rollout(root) is None:
            raise AssertionError('Full owner fence was cleared before global commit')
        unit = role_bootstrap.unit_name(role,edge_id)
        run(['systemctl','start',unit])
        deadline=time.monotonic()+20
        while True:
            status=dict(line.split('=',1) for line in run(['systemctl','show',unit,
                '--property=ActiveState,Result,ExecMainStatus,NRestarts']).decode().splitlines() if '=' in line)
            if status.get('ActiveState') in ('inactive','failed') or time.monotonic()>=deadline:break
            time.sleep(.1)
        if status != {'ActiveState':'inactive','Result':'success','ExecMainStatus':'0','NRestarts':'0'}:
            raise AssertionError('Full fence failed to suppress actual role boot')
        if any(value != 'false' for value in run(['docker','inspect','--format',
                '{{.State.Running}}',*identifiers]).decode().split()):
            raise AssertionError('Boot fence restarted a stopped role')
    return snapshots


def check_configure_snapshots(snapshots, *, run):
    for name,expected in snapshots.items():
        root=Path(name);role='core' if root.name=='core' else 'edge'
        state=core_deploy.read_state(root) if role=='core' else edge_deploy.read_state(root,'a')
        compose=core_deploy.compose if role=='core' else edge_deploy.compose
        identifier=compose(root,state['current'],'ps','-a','-q','configure',execute=run).decode().strip()
        if run(['docker','inspect','--format','{{.Id}} {{.State.StartedAt}} {{.RestartCount}}',identifier]) != expected:
            raise AssertionError('Committed full recovery re-executed configure')


def fault_sequence(root,core,edge,shared,deploy,api,path,account_data,retained_volumes,*,run):
    # Write new account data after the stopped-writer snapshot. A rollback that
    # restored that snapshot would lose it, even if account login still worked.
    def before_public(*args,**kwargs):
        record=edge_deploy.read_state(edge,'a')['current']
        release=role_deploy.release_path(edge,record)
        model=json.loads(edge_deploy.compose(edge,record,'config','--format','json',execute=run))
        owned=initial_cohost.namespace('voicechat-edge-a',
            [((release/'infra/compose.edge.json',),model)],execute=run)['turn']
        retained_volumes.extend(item['Name'] for item in owned['mounts'] if item['Destination']=='/var/lib/coturn')
        account_data['nonce']=secrets.token_hex(16)
        api('http://10.88.0.1:8088',path,'PUT',account_data)
        raise ValueError('Injected failure before public commit')
    with patch.object(shared_cutover,'_activate_locked',side_effect=before_public):
        try:deploy()
        except ValueError as error:
            if str(error)!='Injected failure before public commit':raise
        else:raise AssertionError('Expected pre-public rollback')
    if managed_state.read(root/'initial.json')['phase']!='rolled-back':
        raise AssertionError('Initial controller did not finish legacy rollback')
    if api('http://127.0.0.1:8088',path)!=account_data:
        raise AssertionError('Legacy rollback restored stale account data')
    run(['systemctl','is-active','--quiet',legacy_backup.TIMER])
    original_persist=managed_state.persist;original_activate=shared_cutover._activate_locked
    lost={'core':False,'public':False}
    def core_reply(path,value):
        original_persist(path,value)
        if (path==core/'state.json' and value.get('current') is not None and
                value.get('pending') is None and not lost['core']):
            lost['core']=True
            raise SystemExit('Injected lost committed core reply')
    def public_reply(*args,**kwargs):
        result=original_activate(*args,**kwargs)
        if not lost['public']:
            lost['public']=True
            raise RuntimeError('Injected lost committed public reply')
        return result
    with patch.object(managed_state,'persist',side_effect=core_reply), \
            patch.object(shared_cutover,'_activate_locked',side_effect=public_reply):
        try:deploy(retry=True)
        except SystemExit as error:
            if str(error)!='Injected lost committed core reply':raise
        else:raise AssertionError('Expected core commit interruption')
        if managed_state.read(root/'initial.json')['phase']!='core':
            raise AssertionError('Lost core reply did not preserve its global phase')
        core_snapshot=fenced_stop(core,edge,run=run,roles=('core',))
        try:deploy()
        except RuntimeError as error:
            if str(error)!='Injected lost committed public reply':raise
        else:raise AssertionError('Expected public commit interruption')
        check_configure_snapshots(core_snapshot,run=run)
        if managed_state.read(root/'initial.json')['phase']!='finish':
            raise AssertionError('Committed public transition did not select forward recovery')
        public_snapshot=fenced_stop(core,edge,run=run)
        current=deploy()
        check_configure_snapshots(public_snapshot,run=run)
    return current


def exercise(old_root,baseline,neighbor,session,*,control_image,web_image,run,fault_drills=False,managed_backend=None):
    base=Path('/srv/voicechat-edge-fixture')
    if (sys.platform!='linux' or os.geteuid()!=0 or old_root.parent!=base or old_root.resolve()!=old_root or
            base.is_symlink()):raise ValueError('Use the marked disposable VM fixture root')
    host=' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if json.loads((base/'.disposable-vm').read_text())!={'kind':'voicechat-disposable-vm',
            'ssh_host_key_sha256':hashlib.sha256(host.encode()).hexdigest()}:
        raise ValueError('Disposable VM marker differs from this host')
    if Path('/var/lib/voicechat-network').exists():
        raise ValueError('Isolate the original marked VM network before creating legacy resources')
    directory=Path(tempfile.mkdtemp(prefix='cohost-fixture-',dir=old_root.parent));directory.chmod(0o700)
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
    initial_entry.request(json.dumps({'schema':1,'root':str(root),'legacy_root':str(old_root),
        'shared_root':str(directory/'shared'),'public':public,'inventory':inventory,'subnet':'10.241.0.0/28',
        'catalog':json.loads(envelope),'catalog_key':catalog_key}).encode())
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
    backend=(managed_backend if managed_backend is not None else hashlib.sha256(b'synthetic-full-vm-candidate').hexdigest())
    if not isinstance(backend,str) or not role_release.SHA.fullmatch(backend):raise ValueError('Exact fixture backend fingerprint required')
    result=None
    retained_volumes=[]
    try:
        with business(directory,edge,public,inventory,neighbor,run=run) as (shared,execute,ca):
            try:
                print('Full fixture: starting journaled initial migration',file=sys.stderr,flush=True)
                def deploy(**options):
                    return initial_cohost.migrate(root,old_root,shared,public,inventory,candidate,envelope,catalog_key,
                        backend_sha256=backend,execute=execute,ca_file=ca,**options)
                current=(fault_sequence(root,core,edge,shared,deploy,api,path,account_data,retained_volumes,run=run)
                         if fault_drills else deploy())
                assert current['data_identity']==baseline['data_identity']
                assert core_deploy.data_identity(core,core_deploy.read_state(core)['current'],execute=execute)==baseline['data_identity']
                assert managed_state.read(root/'initial.json')['phase']=='complete'
                private_origin='http://'+inventory['core']['tunnel_ip']+':8088'
                who=api(private_origin,'/_matrix/client/v3/account/whoami')
                assert who['user_id']==session['user_id'] and who['device_id']==session['device_id']
                assert api(private_origin,path)==account_data
                assert (old_root/'current.json').read_bytes()==legacy_pointer
                retirement=initial_cohost.legacy_guard(old_root,root,current['target'])
                assert managed_state.read(old_root/'role-deployment.json')==retirement
                try:initial_cohost.legacy.deploy(old_root,old_root/'releases/forbidden',None)
                except SystemExit as error:
                    if 'core/edge roles' not in str(error):raise
                else:raise AssertionError('Legacy controller ignored the retirement marker')
                typed=managed_release.from_initial(current)
                planned=managed_release.plan(typed,candidate,typed['backend'],scope='web')
                assert planned['core']==typed['core']
                assert planned['steps']==[{'role':'edge','edge_id':'a'}]
                actual_core=managed_release.inspect_role(core,public,inventory,typed['core'],execute=execute)
                actual_edge=managed_release.inspect_role(edge,public,inventory,typed['edges']['a'],execute=execute)
                assert actual_core['data_identity']==baseline['data_identity']
                assert len(actual_core['processes'])==3 and len(actual_edge['processes'])==3
                for role_root in (core,edge):assert not (role_root/'runtime/full-rollout.json').exists()
                assert initial_cohost.migrate(root,old_root,shared,public,inventory,candidate,envelope,catalog_key,
                    backend_sha256=backend,execute=execute,ca_file=ca)==current
                result={'full_initial_cohost_migration_committed':True,'same_target_complete_resume':True,
                    'account_device_account_data_database_and_signing_identity_preserved':True,
                    'legacy_release_pointer_unchanged':True,'production_changed':False,
                    'legacy_controller_retired_before_runtime_or_docker':True,
                    'typed_initial_baseline_and_web_scope_plan_verified':True,
                    'actual_core_edge_baseline_reader_verified':True,
                    'limits':['Synthetic accounts, CA, catalog key and candidate fingerprint on the marked VM.',
                              'No real device/media acceptance, production transition or actual machine reboot.'],
                    'pre_public_rollback_and_committed_core_public_recovery_drills':fault_drills}
                if managed_backend is not None:
                    from managed_rollout_fixture import wait
                    result['managed_ssh']=wait(root,public,inventory,session,path,baseline['data_identity'],run=run)
            finally:
                expected={}
                for role_root,role,edge_id in ((core,'core',None),(edge,'edge','a')):
                    name,_,_,unit,_=role_bootstrap.plan(role_root,role,edge_id)
                    receipt_path=role_root/'runtime/boot/current.json'
                    if receipt_path.exists() or receipt_path.is_symlink():
                        receipt=managed_state.read(receipt_path)
                        if role_bootstrap.verify_record(Path('/'),receipt)!=name:
                            raise ValueError('Fixture boot receipt belongs to another role')
                        unit=(units/name).read_bytes()
                        if receipt['root']!=str(role_root) or hashlib.sha256(unit).hexdigest()!=receipt['unit_sha256']:
                            raise ValueError('Changed fixture role boot unit must be preserved')
                    expected[name]=unit
                # Scheduler files can be derived only after the package exists.
                for location,module in ((shared/'tls-renewal',cohost_tls_bootstrap),(core/'runtime/backup-boot',core_backup_bootstrap)):
                    receipt=location/'current.json';pending=location/'pending.json'
                    record=(managed_state.read(receipt) if receipt.exists() else
                            managed_state.read(pending)['target'] if pending.exists() else None)
                    if record is not None:expected.update(module.files(record,system_root=Path('/')))
                remove_units(expected,(cohost_tls_bootstrap.TIMER,core_backup_bootstrap.TIMER),run=run)
                initial=initial_cohost.target_for(root,old_root,shared,public,inventory,candidate,catalog_key,
                    subnet='10.241.0.0/28',backend_sha256=backend)
                for role_root,role in ((edge,'edge'),(core,'core')):
                    if (role_root/'role.json').exists():
                        cleanup_role(role_root,public,inventory,initial[role],run=execute)
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
        for volume in retained_volumes:
            if not run(['docker','volume','ls','-q','--filter','name=^'+volume+'$']).strip():continue
            info=json.loads(run(['docker','volume','inspect',volume]))[0]
            if (info['Name']!=volume or info['Driver']!='local' or info.get('Options') or
                    'com.docker.volume.anonymous' not in (info.get('Labels') or {}) or
                    run(['docker','ps','-aq','--filter','volume='+volume]).strip()):
                raise ValueError('Unknown retained fixture volume must be preserved')
            run(['docker','volume','rm',volume])
            if run(['docker','volume','ls','-q','--filter','name=^'+volume+'$']).strip():
                raise AssertionError('Retained fixture volume was not removed')
        for name,path in stamps.items():
            if not prior_stamps[name] and path.exists():path.unlink()
    if result is None:raise AssertionError('Full migration did not complete')
    shutil.rmtree(directory)
    return result
