"""Frozen-source coordinator entry: journal mutations stay on the data host A."""
import argparse
import json
import os
from pathlib import Path
import platform
import sys

import managed_control
import managed_finish
import managed_journal
import managed_state
import network_bootstrap
import node_inventory
import role_release
import topology

MAX_INPUT=65536
ACTIONS={
    'status':(),
    'prepare':('scope','edges','position','baseline'),
    'begin':('scope','edges','baseline','retry'),
    'next':('attempt',),
    'ack':('attempt','phase','position','proof'),
    'commit':('attempt',),
    'rollback':('attempt',),
    'finish':('attempt',),
}


def request(raw):
    if len(raw)>MAX_INPUT:raise ValueError('Managed coordinator input is too large')
    value=json.loads(raw.decode('utf-8'),object_pairs_hook=topology.unique_object)
    if not isinstance(value,dict) or not isinstance(value.get('action'),str) or value['action'] not in ACTIONS:
        raise ValueError('Known coordinator action required')
    topology.fields(value,('schema','action',*ACTIONS[value['action']]))
    if type(value['schema']) is not int or value['schema']!=1:raise ValueError('Known coordinator schema required')
    for key in ('attempt','baseline'):
        if key in value and value[key] is not None and (not isinstance(value[key],str) or not role_release.SHA.fullmatch(value[key])):
            raise ValueError('Exact attempt/baseline digest required')
    if 'attempt' in value and value['attempt'] is None:raise ValueError('Exact attempt required')
    if 'scope' in value:
        if value['scope'] not in ('web','edge','core','full'):raise ValueError('Known release scope required')
        if value['edges'] is not None and (not isinstance(value['edges'],list) or
                not value['edges'] or any(not isinstance(item,str) for item in value['edges'])):
            raise ValueError('Explicit edge list or null required')
    if 'position' in value and (type(value['position']) is not int or value['position']<0):
        raise ValueError('Nonnegative operation position required')
    if 'retry' in value and (type(value['retry']) is not bool or value['baseline'] is None):
        raise ValueError('Explicit retry flag and baseline required')
    return value


def operate(value,root,source_sha,*,source=None):
    root=managed_journal._root(root)
    source=Path(source) if source is not None else Path(__file__).resolve().parents[1]
    if (not isinstance(source_sha,str) or not role_release.SHA.fullmatch(source_sha) or
            source!=root/'bundles'/source_sha or source.resolve()!=source):
        raise ValueError('Use this exact immutable coordinator source')
    managed_journal._delivery(root,source_sha)
    if platform.system()!='Linux' or os.geteuid()!=0:raise ValueError('Coordinator requires data host A as root')
    # This lock serializes complete request/response operations independently of
    # the journal's smaller atomic mutations; it is never held across SSH calls.
    with managed_state.locked(root/'coordinator'):
        pointer,baseline,_=managed_journal.current(root)
        actual=network_bootstrap.existing(Path('/etc/ssh/ssh_host_ed25519_key.pub'))
        if actual is None or node_inventory.host_key(' '.join(actual.decode().split()[:2]))!=baseline['inventory']['core']['ssh_host_key']:
            raise ValueError('Coordinator belongs to another pinned SSH data host')
        path=root/'rollout.json'
        pending=managed_state.read(path) if path.exists() or path.is_symlink() else None
        action=value['action']
        if pending is not None and pending.get('phase') not in ('complete','rolled-back'):
            original=pending.get('request',{}).get('source')
            if original!=source_sha:
                managed_journal._delivery(root,original)
                if action!='status':raise ValueError('Resume the active coordinator from its original frozen source')
                return {'schema':1,'active_source':original,'attempt':pending['attempt'],'phase':pending['phase']}
        if action=='finish':
            if pending is None or pending.get('request',{}).get('source')!=source_sha:
                raise ValueError('Finish maintenance from its original frozen release source')
            return managed_finish.finish(root,value['attempt'])
        if action=='status':
            journal=managed_journal.read(root) if pending is not None else None
            return {'schema':1,'active_source':journal['request']['source'] if journal is not None else None,
                    'attempt':journal['attempt'] if journal is not None else None,
                    'phase':journal['phase'] if journal is not None else None,
                    'baseline':role_release.json_digest(baseline),'backend':baseline['backend'],
                    'origin':baseline['public']['canonical_origin'],'control':baseline['core']['images']['control'],
                    'web':{key:item['images']['web'] for key,item in baseline['edges'].items()}}
        if action=='prepare':
            return managed_control.prepare(root,source_sha,scope=value['scope'],edges=value['edges'],
                position=value['position'],expected_baseline=value['baseline'])
        if action=='begin':
            journal=managed_journal.begin(root,source_sha,value['baseline'],scope=value['scope'],edges=value['edges'],retry=value['retry'])
            attempt=journal['attempt']
        else:
            attempt=value['attempt']
            if action=='ack':managed_journal.acknowledge(root,attempt,value['phase'],value['position'],value['proof'])
            elif action=='commit':managed_journal.commit(root,attempt)
            elif action=='rollback':managed_journal.start_rollback(root,attempt)
        result=managed_control.next_operation(root,attempt)
        if len(json.dumps(result).encode())>MAX_INPUT:raise ValueError('Coordinator response exceeds bounded SSH contract')
        return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True);parser.add_argument('--source-sha',required=True)
    args=parser.parse_args()
    try:
        result=operate(request(sys.stdin.buffer.read(MAX_INPUT+1)),args.root,args.source_sha)
    except BlockingIOError:
        parser.exit(75,'Managed operation is busy; preserve and resume its journal\n')
    print(json.dumps(result))


if __name__=='__main__':main()
