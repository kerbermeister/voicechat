"""Apply one claimed role and return facts from its committed running state.

Host provisioning, catalog publication and the global commit belong to the
coordinator. A lost reply after role commit never replays application configure.
"""
from pathlib import Path

import core_deploy
import edge_deploy
import managed_fence
import managed_state
import role_bootstrap
import role_deploy
import role_release


def apply(root, public, inventory, before, target, attempt, *, scope=None,
          core_manifest=None, subnet='10.241.0.0/28', system_root=Path('/'),
          execute=role_deploy.run, run=role_bootstrap.service_command):
    root = managed_fence._parameters(root,public,inventory,before,target,attempt,system_root)
    role, edge_id = target['role'], target['edge_id']
    if role == 'core':
        if scope is not None or core_manifest is not None:
            raise ValueError('Core apply does not take edge scope or another core manifest')
    else:
        if scope not in ('web','edge') or core_manifest is None:
            raise ValueError('Edge apply requires scope and the verified running core manifest')
        role_release.require_compatible(core_manifest,target)
        if scope == 'web': role_release.require_web_only(before,target)
    with managed_state.locked(root):
        intent = managed_fence._owned(root,before,target,attempt)
        if intent['phase'] != 'held' or intent['active'] != target:
            raise ValueError('Apply requires this operation active target fence')
        role_deploy.require_rollout_owner(root,attempt,target)
        state = managed_fence._state(root,target)
        if state['current'] is None or state['current']['manifest'] not in (before,target):
            raise ValueError('Another role baseline was committed before apply')
        if state['pending'] is not None and state['pending']['target']['manifest'] != target:
            raise ValueError('Another role deployment is pending')
        committed = state['pending'] is None and state['current']['manifest'] == target
    # Claim has quiesced the old monitor without stopping applications. Replace
    # only its owned, sealed sources; no old monitor may race this installation.
    managed_fence._quiesce(root,target,attempt,run=run)
    role_bootstrap.install(root,role,edge_id,system_root=system_root,run=run)
    if not committed:
        common = {'subnet':subnet,'execute':execute,'rollout_attempt':attempt}
        if role == 'core':
            core_deploy.deploy(root,public,inventory,target,**common)
        else:
            edge_deploy.deploy(root,public,inventory,target,core_manifest,scope=scope,**common)
    return managed_fence.observe(root,public,inventory,before,target,target,attempt,
        subnet=subnet,system_root=system_root,execute=execute,run=run)
