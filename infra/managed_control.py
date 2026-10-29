"""Bounded coordinator instructions derived from A's durable release journal.

One response contains one role, so a 32-edge installation never requires an
oversized JSON document. This module does not manufacture role health proofs.
"""
import json

import managed_journal
import managed_peer
import managed_release
import managed_state
import node_inventory
import role_release


def _role(baseline,step):
    return baseline['core'] if step['role']=='core' else baseline['edges'][step['edge_id']]


def instruction(baseline,target,step,attempt,scope,operation,identity,*,restoring=False):
    before,after=_role(baseline,step),_role(target,step)
    role,identifier=step['role'],step['edge_id']
    node=baseline['inventory']['core'] if role=='core' else node_inventory.edge_assignment(baseline['inventory'],identifier)
    value={'schema':1,'operation':operation,'public':baseline['public'],'inventory':baseline['inventory'],
           'subnet':baseline['subnet'],'before':before,'target':after,'attempt':attempt,
           'scope':None if role=='core' else ('web' if scope=='web' else 'edge'),
           'core':(baseline if restoring else target)['core'] if role=='edge' and operation=='apply' else None,
           'data_identity':identity if role=='core' else None,
           'manifest':(before if restoring else after) if operation in ('observe','release') else None}
    managed_peer.request(json.dumps(value).encode())
    inventory=baseline['inventory']
    return {'host':node['public_ip'],'host_key':node['ssh_host_key'],
            'user':inventory['ssh_user'],'port':inventory['ssh_port'],'request':value}


def prepare(root,source,*,scope='full',edges=None,position=0,expected_baseline=None):
    root=managed_journal._root(root)
    with managed_state.locked(root):
        if (root/'rollout.json').exists() or (root/'rollout.json').is_symlink():
            journal=managed_journal._load(root)[0]
            if journal['phase'] not in ('complete','rolled-back'):
                raise ValueError('Resume the existing release before preparing another')
        receipt=managed_journal._delivery(root,source)
        pointer,baseline,_=managed_journal.current(root)
        digest=role_release.json_digest(baseline)
        if expected_baseline is not None and expected_baseline!=digest:
            raise ValueError('Production baseline changed during preflight')
        plan=managed_release.plan(baseline,receipt['manifest'],receipt['backend'],scope=scope,edges=edges)
        target={**baseline,'backend':plan['backend'],'core':plan['core'],'edges':plan['edges']}
        participants=[{'role':'core','edge_id':None}]+[step for step in plan['steps'] if step['role']=='edge']
        if type(position) is not int or not 0<=position<len(participants):
            raise ValueError('Known preflight role position required')
        # The nonce is unused by read-only peer preflight; begin allocates the
        # actual random operation owner only after every participant passed.
        return {'schema':1,'source':source,'baseline':digest,'count':len(participants),'position':position,
                'peer':instruction(baseline,target,participants[position],'0'*64,scope,'preflight',pointer['data_identity'])}


def next_operation(root,attempt=None):
    root=managed_journal._root(root)
    with managed_state.locked(root):
        journal,baseline,target,_=managed_journal._load(root,attempt)
        phase=journal['phase'];position=journal['position']
        result={'schema':1,'source':journal['request']['source'],'attempt':journal['attempt'],
                'phase':phase,'position':position,'peer':None}
        if phase in ('committing','complete','rolled-back'):return result
        step=managed_journal._sequence(journal,phase)[position]
        restoring=phase.startswith('rollback') or phase=='rolling-back'
        # Also roll back untouched participants during rollback verification:
        # their fences may still name the candidate despite unchanged apps.
        operation={'fencing':'claim','applying':'apply','verifying':'observe','releasing':'release',
                   'rolling-back':'rollback','rollback-verifying':'rollback','rollback-releasing':'release'}[phase]
        result['peer']=instruction(baseline,target,step,journal['attempt'],journal['request']['scope'],
                                   operation,journal['data_identity'],restoring=restoring)
        return result
