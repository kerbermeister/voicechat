"""Coordinate the real SSH runner with the owned disposable cohost fixture.

Synthetic credentials remain on the VM. The Mac runner receives only public
paths/host pins and writes a nonce-bound completion after its deployment drills.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

BASE=Path('/srv/voicechat-edge-fixture')


def owned(root):
    if os.geteuid()!=0 or root.resolve()!=root or BASE not in root.parents:
        raise ValueError('Owned disposable managed fixture required')
    host=' '.join(Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().split()[:2])
    if json.loads((BASE/'.disposable-vm').read_text())!={'kind':'voicechat-disposable-vm',
            'ssh_host_key_sha256':hashlib.sha256(host.encode()).hexdigest()}:
        raise ValueError('Disposable VM host marker changed')


def save(path,value):
    with path.open('x') as output:json.dump(value,output)
    path.chmod(0o600)


def api(context,path,method='GET',body=None):
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request=urllib.request.Request(context['origin']+path,None if body is None else json.dumps(body).encode(),
        {'Content-Type':'application/json','Authorization':'Bearer '+context['session']['access_token']},method=method)
    with opener.open(request,timeout=20) as response:return json.load(response)


def wait(root,public,inventory,session,account_path,data_identity,*,run,timeout=3600):
    import core_deploy,edge_deploy,managed_state,role_deploy,role_release
    owned(root)
    directory=root/'managed-test';directory.mkdir(mode=0o700)
    import secrets
    nonce=secrets.token_hex(32)
    context={'schema':1,'nonce':nonce,'root':str(root),'session':session,'account_path':account_path,
             'origin':'http://'+inventory['core']['tunnel_ip']+':8088','data_identity':data_identity}
    save(directory/'context.json',context)
    initial=api(context,account_path);save(directory/'expected.json',initial)
    def neighbors():
        identifiers=run(['docker','ps','-q','--no-trunc']).decode().split()
        rows=json.loads(run(['docker','inspect',*identifiers]))
        return sorted(item['Id']+' '+item['State']['StartedAt']+' '+str(item['RestartCount']) for item in rows
            if (item['Config'].get('Labels') or {}).get('com.docker.compose.project') not in ('voicechat','voicechat-edge-a'))
    before=neighbors()
    save(directory/'ready.json',{'schema':1,'root':str(root),'nonce':nonce,'public':public,'inventory':inventory})
    print('Managed SSH fixture ready: '+str(root),flush=True)
    deadline=time.monotonic()+timeout
    done=directory/'done.json'
    while not done.exists():
        if time.monotonic()>=deadline:raise TimeoutError('Managed SSH runner did not complete; fixture cleanup follows')
        time.sleep(.5)
    completed=json.loads(done.read_text())
    if (set(completed)!={'schema','nonce','full','web','rollback','lost_reply'} or completed['schema']!=1 or
            completed['nonce']!=nonce or any(completed[key] is not True for key in ('full','web','rollback','lost_reply'))):
        raise ValueError('Expected all nonce-bound managed SSH drills')
    who=api(context,'/_matrix/client/v3/account/whoami')
    assert who['user_id']==session['user_id'] and who['device_id']==session['device_id']
    assert api(context,account_path)==json.loads((directory/'expected.json').read_text())
    core=root/'core';state=core_deploy.read_state(core)
    assert state['pending'] is None and core_deploy.data_identity(core,state['current'],execute=run)==data_identity
    for role_root in (core,root/'edges/a'):
        assert not (role_root/'runtime/full-rollout.json').exists()
        assert role_deploy.managed_operation(role_root)['phase']=='released'
    assert json.loads((root/'rollout.json').read_text())['phase']=='rolled-back'
    assert neighbors()==before,'Neighboring Caddy/frontend/front process changed'
    return {'actual_pinned_ssh_full_web_and_rollback':True,'lost_apply_reply_resumed_without_reconfigure':True,
            'synthetic_account_device_post_backup_data_and_identity_preserved':True,
            'neighbor_processes_unchanged':True,'all_role_fences_released':True}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--write');parser.add_argument('--snapshot-core',action='store_true')
    parser.add_argument('--check-core',action='store_true')
    parser.add_argument('--complete',action='store_true')
    args=parser.parse_args();root=args.root.absolute();owned(root)
    directory=root/'managed-test';context=json.loads((directory/'context.json').read_text())
    if context['root']!=str(root) or context['schema']!=1:raise ValueError('Synthetic test context differs')
    if args.write:
        value={'nonce':args.write};api(context,context['account_path'],'PUT',value)
        path=directory/'expected.json';path.write_text(json.dumps(value));path.chmod(0o600)
    if args.snapshot_core or args.check_core:
        import sys
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'infra'))
        import core_deploy,managed_release
        role_root=root/'core';record=core_deploy.read_state(role_root)['current']
        actual=managed_release.process_snapshot(role_root,record)
        path=directory/'core-before-web.json'
        if args.snapshot_core:save(path,actual)
        if args.check_core:assert json.loads(path.read_text())==actual,'Web-only changed core processes'
    if args.complete:
        import sys
        sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'infra'))
        import managed_state
        managed_state.persist(directory/'done.json',{'schema':1,'nonce':context['nonce'],
            'full':True,'web':True,'rollback':True,'lost_reply':True})
    print(json.dumps({'schema':1,'synthetic_check_passed':True}))


if __name__=='__main__':main()
