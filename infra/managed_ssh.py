"""Pinned SSH driver for ordinary managed releases; secrets stay on their hosts."""
import argparse
from contextlib import contextmanager
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import time

import host_connection
import managed_entry
import managed_peer
import managed_probe
import release_source
import role_release
import node_inventory
import release_delivery
import ssh_deploy
import topology
from tunnel_config import physical_nodes


class RemoteFailure(RuntimeError):
    pass


@contextmanager
def connection(peer,identity):
    inventory=peer.get('inventory') or peer['request']['inventory']
    nodes=physical_nodes(inventory);node=peer['node']
    if node not in nodes:raise ValueError('Unknown physical SSH node')
    expected={'host':nodes[node]['public_ip'],'host_key':nodes[node]['ssh_host_key'],
              'user':inventory['ssh_user'],'port':inventory['ssh_port']}
    if any(peer[key]!=value for key,value in expected.items()):
        raise ValueError('SSH instruction differs from its physical inventory')
    if isinstance(identity,dict):
        if node not in identity:raise ValueError('Configure this physical node SSH identity first')
        identity=identity[node]
    with host_connection.connection(inventory,node,identity) as ssh:yield ssh


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


def read_hints(ssh,root):
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+',str(root)) or '..' in Path(root).parts:
        raise ValueError('Canonical managed root required')
    script=Path(__file__).with_name('managed_probe.py').read_bytes()
    result=subprocess.run([*ssh,shlex.join(['python3','-B','-',str(root)])],input=script,
                          capture_output=True,timeout=60)
    if result.returncode:raise RemoteFailure('Managed build hint read failed; inspect the pinned data host')
    if len(result.stdout)>65536:raise ValueError('Oversized build hints')
    value=json.loads(result.stdout,object_pairs_hook=managed_probe.unique)
    topology.fields(value,('schema','baseline','backend','origin','control','web','pending','core_guard'))
    if type(value['schema']) is not int or value['schema']!=1:
        raise ValueError('Known managed build hints required')
    if value['core_guard'] is not None and (not isinstance(value['core_guard'],str) or not role_release.SHA.fullmatch(value['core_guard'])):
        raise ValueError('Known core source guard required')
    return value


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
            if phase in ('applying','verifying'):
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
                not isinstance(proof['facts'],dict) or proof['facts'].get('manifest')!=peer['request']['before']):
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
    parser.add_argument('--identity-map',type=Path)
    actions=parser.add_mutually_exclusive_group()
    actions.add_argument('--read-build-hints',action='store_true')
    actions.add_argument('--resume-only',action='store_true')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    config=json.loads(os.environ['SERVER_ROLE_CONFIG'],object_pairs_hook=topology.unique_object)
    node_inventory.validate(config['inventory'],config['public'])
    root=os.environ['DEPLOY_ROOT']
    if config['root']!=root:raise ValueError('Managed installation differs from DEPLOY_ROOT')
    inventory=config['inventory'];node=inventory['core']
    peer={'node':'core','inventory':inventory,'host':node['public_ip'],'host_key':node['ssh_host_key'],'user':inventory['ssh_user'],'port':inventory['ssh_port']}
    identity=args.identity
    if args.identity_map is not None:
        _,identity=managed_probe.read(args.identity_map)
        if not isinstance(identity,dict) or not identity:
            raise ValueError('Physical node to SSH identity/profile map required')
        for name, value in identity.items():
            host_connection.parameters(inventory, name, value)
    elif any(edge.get('host')!='core' for edge in inventory['edges']):
        raise ValueError('Configure separate SSH identities for physical nodes using --identity-map')
    with connection(peer,identity) as ssh:
        if args.read_build_hints or args.resume_only:
            hints=read_hints(ssh,root)
            if hints['origin']!=os.environ['PUBLIC_URL']:raise ValueError('Build origin differs from the deployed service')
            if args.resume_only:
                pending=hints['pending']
                result=({'schema':1,'resume_needed':False} if pending is None else
                        drive(ssh,root,pending['source'],identity))
                if result.get('phase')=='rolled-back' and not args.retry:
                    raise RemoteFailure('Previous managed release rolled back; use explicit retry')
            else:
                if hints['pending'] is not None and hints['pending']['phase'] not in ('complete','rolled-back'):
                    raise ValueError('Resume the pending release before selecting build digests')
                if args.scope in ('web','edge') and hints['backend']!=release_source.backend_fingerprint(Path(__file__).resolve().parents[1]):
                    raise ValueError('Protected backend sources changed; use full release')
                if args.scope=='core' and hints['backend']!=release_source.backend_fingerprint(Path(__file__).resolve().parents[1]):
                    guard=release_source.core_scope_fingerprint(Path(__file__).resolve().parents[1])
                    if hints['core_guard'] is None or hints['core_guard']!=guard:
                        raise ValueError('Non-core protected sources changed or guard missing; use full release')
                result=hints
        else:
            result=release(ssh,root,os.environ['GITHUB_SHA'],args.archive,identity,
                           scope=args.scope,edges=args.edges,retry=args.retry)
    if args.output is not None:
        descriptor=os.open(args.output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(descriptor,'w') as output:json.dump(result,output);output.write('\n')
    else:print(json.dumps(result))


if __name__=='__main__':main()
