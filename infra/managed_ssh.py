"""Pinned SSH driver for ordinary managed releases; secrets stay on their hosts."""
import argparse
from contextlib import contextmanager
import json
import os
import re
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import time

import managed_entry
import managed_peer
import node_inventory
import release_delivery
import ssh_deploy
import topology


class RemoteFailure(RuntimeError):
    pass


@contextmanager
def connection(peer,identity):
    host=node_inventory.ipv4(peer['host'])
    key=node_inventory.host_key(peer['host_key'])
    user=peer['user'];port=peer['port']
    # Reuse the inventory validator for the common transport contract.
    if not isinstance(user,str) or not re.fullmatch(r'[a-z_][a-z0-9_-]*',user) or type(port) is not int or not 1<=port<=65535:
        raise ValueError('Pinned SSH user and port required')
    identity=Path(identity).absolute()
    info=identity.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_mode&0o077:
        raise ValueError('Owned private SSH identity required')
    with tempfile.TemporaryDirectory(prefix='voicechat-managed-ssh-') as folder:
        known=Path(folder)/'known_hosts'
        known.write_text((host if port==22 else '['+host+']:'+str(port))+' '+key+'\n');known.chmod(0o600)
        yield ['ssh','-F','/dev/null','-T','-i',str(identity),'-p',str(port),
            '-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',
            '-o','UserKnownHostsFile='+str(known),'-o','GlobalKnownHostsFile=/dev/null',
            '-o','ForwardAgent=no','-o','ClearAllForwardings=yes','-o','ConnectTimeout=10',
            '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2',user+'@'+host]


def invoke(ssh,root,source,entry,value):
    if entry not in ('managed_entry','managed_peer') or not isinstance(source,str) or not release_delivery.SHA.fullmatch(source):
        raise ValueError('Frozen managed entry required')
    parser=managed_entry.request if entry=='managed_entry' else managed_peer.request
    raw=json.dumps(value,separators=(',',':')).encode();parser(raw)
    path=Path(root)
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+',str(path)) or path==Path('/') or '..' in path.parts:
        raise ValueError('Canonical managed root required')
    command=['python3','-B',str(path/'bundles'/source/'infra'/ (entry+'.py')),
             '--root',str(path),'--source-sha',source]
    for attempt in range(3):
        try:result=subprocess.run([*ssh,shlex.join(command)],input=raw,capture_output=True,timeout=1800)
        except subprocess.TimeoutExpired:
            if attempt==2:raise RuntimeError('SSH result is uncertain; resume the existing release journal') from None
        else:
            if result.returncode==0:
                if len(result.stdout)>1024*1024:raise ValueError('Managed SSH response exceeds its bound')
                value=json.loads(result.stdout.rstrip(b'\n').rsplit(b'\n',1)[-1])
                if len(json.dumps(value).encode())>65536:raise ValueError('Oversized managed completion record')
                return value
            if result.returncode not in (75,255):
                raise RemoteFailure('Managed '+entry+' operation failed; consult the owned host journal')
            if attempt==2:raise RuntimeError('SSH/role is still busy or unavailable; preserve the release journal')
        time.sleep(attempt+1)


def _coordinator(ssh,root,source,action,**values):
    return invoke(ssh,root,source,'managed_entry',{'schema':1,'action':action,**values})


def drive(ssh,root,source,identity,*,connect=connection):
    """Resume the journal, never replay a global commit backwards."""
    for _ in range(512):
        result=_coordinator(ssh,root,source,'status')
        attempt=result['attempt']
        if attempt is None:raise ValueError('Begin the managed release before driving it')
        if result['active_source']!=source:raise ValueError('Use the original frozen coordinator source')
        operation=_coordinator(ssh,root,source,'next',attempt=attempt)
        phase=operation['phase']
        if phase in ('complete','rolled-back'):
            return _coordinator(ssh,root,source,'finish',attempt=attempt)
        if phase=='committing':
            _coordinator(ssh,root,source,'commit',attempt=attempt);continue
        peer=operation['peer']
        print('Managed release: '+phase+' '+peer['request']['target']['role']+
              ('-'+peer['request']['target']['edge_id'] if peer['request']['target']['edge_id'] else ''),flush=True)
        try:
            with connect(peer,identity) as remote:
                proof=invoke(remote,root,source,'managed_peer',peer['request'])
        except RemoteFailure:
            if phase in ('fencing','applying','verifying'):
                _coordinator(ssh,root,source,'rollback',attempt=attempt);continue
            raise
        _coordinator(ssh,root,source,'ack',attempt=attempt,phase=phase,position=operation['position'],proof=proof)
    raise RuntimeError('Managed release exceeded its bounded operation count; preserve the journal')


def release(ssh,root,commit,archive,identity,*,scope='full',edges=None,retry=False,connect=connection):
    delivery=ssh_deploy.receive(ssh,root,commit,archive)
    source=delivery['archive_sha256']
    status=_coordinator(ssh,root,source,'status')
    if status['attempt'] is not None:
        previous=status['active_source']
        finished=drive(ssh,root,previous,identity,connect=connect)
        if finished['phase']=='rolled-back' and not retry:
            raise RemoteFailure('Previous managed release rolled back; use explicit retry')
        if (previous==source and finished['phase']=='complete' and finished['scope']==scope and
                finished['selected_edges']==edges):return finished
    first=_coordinator(ssh,root,source,'prepare',scope=scope,edges=edges,position=0,baseline=None)
    baseline=first['baseline'];delivered=set()
    for position in range(first['count']):
        plan=first if position==0 else _coordinator(ssh,root,source,'prepare',scope=scope,edges=edges,
                                                    position=position,baseline=baseline)
        if plan['baseline']!=baseline or plan['count']!=first['count'] or plan['position']!=position:
            raise ValueError('Preflight plan changed while staging public sources')
        peer=plan['peer'];node=tuple(peer[key] for key in ('host','host_key','user','port'))
        with connect(peer,identity) as remote:
            if position==0:
                # Coordinator and first role are the same verified data host.
                delivered.add(node)
            if node not in delivered:
                installed=ssh_deploy.receive(remote,root,commit,archive)
                if installed!=delivery:raise ValueError('Hosts received different immutable source packages')
                delivered.add(node)
            proof=invoke(remote,root,source,'managed_peer',peer['request'])
        if (not isinstance(proof,dict) or set(proof)!= {'facts','fence'} or proof['fence'] is not None or
                proof['facts'].get('manifest')!=peer['request']['before']):
            raise ValueError('Peer preflight did not confirm the expected running baseline')
        if peer['request']['target']['role']=='core' and proof['facts'].get('data_identity')!=peer['request']['data_identity']:
            raise ValueError('Data identity changed during release preflight')
    _coordinator(ssh,root,source,'begin',scope=scope,edges=edges,baseline=baseline,retry=retry)
    result=drive(ssh,root,source,identity,connect=connect)
    if result['phase']=='rolled-back':raise RemoteFailure('Managed release rolled back; previous applications retained')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scope',choices=('web','edge','core','full'),default='full')
    parser.add_argument('--edges',nargs='+');parser.add_argument('--retry',action='store_true')
    parser.add_argument('--archive',type=Path,default=Path('/tmp/release.tar.gz'))
    parser.add_argument('--identity',type=Path,default=Path.home()/'.ssh/id_ed25519')
    args=parser.parse_args()
    config=json.loads(os.environ['SERVER_ROLE_CONFIG'],object_pairs_hook=topology.unique_object)
    node_inventory.validate(config['inventory'],config['public'])
    root=os.environ['DEPLOY_ROOT']
    if config['root']!=root:raise ValueError('Managed installation differs from DEPLOY_ROOT')
    inventory=config['inventory'];node=inventory['core']
    peer={'host':node['public_ip'],'host_key':node['ssh_host_key'],'user':inventory['ssh_user'],'port':inventory['ssh_port']}
    with connection(peer,args.identity) as ssh:
        result=release(ssh,root,os.environ['GITHUB_SHA'],args.archive,args.identity,
                       scope=args.scope,edges=args.edges,retry=args.retry)
    print(json.dumps(result))


if __name__=='__main__':main()
