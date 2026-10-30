"""Restore the previous core code/policy after a later role fails.

No database restore, volume removal, runtime secret replacement or migration is
performed. The normal coordinator must first retarget its fence to the baseline.
"""
from pathlib import Path
import subprocess

import core_deploy
import managed_state
import role_bootstrap
import role_deploy
import role_prepare
import role_release
import topology

PHASES = ('stopping', 'restoring', 'starting', 'committed')


def rollback(root, public, inventory, previous_manifest, rejected_manifest, identity, attempt, *,
             subnet='10.241.0.0/28', execute=role_deploy.run,
             check_network=role_deploy.network_ready, check_health=core_deploy.healthy,
             check_boot=role_bootstrap.ready, identify_data=core_deploy.data_identity,
             activate_monitor=role_bootstrap.activate):
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Canonical core root required')
    if not isinstance(attempt,str) or not role_release.SHA.fullmatch(attempt):
        raise ValueError('Owned managed rollback attempt required')
    core_deploy.validate_data_identity(identity)
    for manifest in (previous_manifest,rejected_manifest):
        role_release.verify_configuration(manifest,public,inventory)
        if manifest['role'] != 'core': raise ValueError('Core rollback requires core manifests')
    if any(previous_manifest[key] != rejected_manifest[key] for key in
           ('service_id','identity','contracts','node_sha256','topology_sha256')):
        raise ValueError('Core rollback cannot change installation or host')
    if any(previous_manifest['images'][key] != rejected_manifest['images'][key] for key in ('postgres','synapse')):
        raise ValueError('Database engine rollback requires an explicit migration')
    previous = core_deploy.record_for(root,inventory,previous_manifest)
    rejected = core_deploy.record_for(root,inventory,rejected_manifest)
    with role_bootstrap.monitor_after(root,'core',activate=activate_monitor), managed_state.locked(root), \
            check_network(inventory,'core',subnet,execute=execute):
        role_deploy.require_rollout_owner(root,attempt,previous_manifest)
        core_deploy.require_no_backup(root)
        check_boot(root,'core')
        state = core_deploy.read_state(root)
        if state['current'] not in (previous,rejected) or state['data_identity'] != identity:
            raise ValueError('Core rollback baseline or data identity changed')
        if identify_data(root,state['current'],execute=execute) != identity:
            raise ValueError('Core data identity changed before rollback')
        core_deploy.configuration(root,previous,execute=execute)
        core_deploy.require_backup_idle(root,execute=execute)

        directory = root / 'runtime/core-deploy'
        if directory.exists() or directory.is_symlink(): role_prepare.directory(directory)
        path = directory / ('rollback-' + attempt + '.json')
        exists = path.exists() or path.is_symlink()
        pending = state['pending']

        def verify_identity():
            if core_deploy.runtime_digest(root) != previous['runtime_sha256'] or identify_data(root,previous,execute=execute) != identity:
                raise ValueError('Core runtime or data identity changed during rollback')

        def recover_committed():
            try:
                check_health(root,previous,execute=execute)
            except (ValueError,OSError,RuntimeError,subprocess.SubprocessError):
                core_deploy.start_committed(root,previous,execute=execute)
                check_health(root,previous,execute=execute)
            verify_identity()

        if not exists and state['current'] == previous:
            # Never replay configure when the inner deploy already rolled back,
            # or when it was cancelled before it could change configuration.
            if pending is None:
                recover_committed()
                return previous
            if pending['target'] != rejected or pending['phase'] == 'managed-rollback':
                raise ValueError('Another core deployment is pending')
            untouched = pending['phase'] == 'prepared'
            if pending['phase'] == 'stopping':
                snapshot = core_deploy.policy_path(root,rejected)
                untouched = not snapshot.exists() and not snapshot.is_symlink()
            if untouched:
                recover_committed()
                managed_state.persist(root/'state.json',{**state,'pending':None})
                return previous

        if exists:
            journal = managed_state.read(path)
            topology.fields(journal,('schema','operation','root','attempt','previous','rejected',
                                     'data_identity','previous_pointer','policy_sha256','phase'))
            if (type(journal['schema']) is not int or journal['schema'] != 1 or
                    journal['operation'] != 'managed-core-rollback' or journal['root'] != str(root) or
                    journal['attempt'] != attempt or journal['previous'] != previous or journal['rejected'] != rejected or
                    journal['data_identity'] != identity or journal['phase'] not in PHASES or
                    not isinstance(journal['policy_sha256'],str) or not role_release.SHA.fullmatch(journal['policy_sha256'])):
                raise ValueError('Resume the same valid managed core rollback')
            if journal['previous_pointer'] is not None: core_deploy.validate_record(journal['previous_pointer'])
        else:
            if state['current'] == rejected:
                if pending is not None or state['previous'] != previous:
                    raise ValueError('Committed rejected core has another previous/pending release')
            elif pending is None or pending['target'] != rejected or pending['phase'] not in ('stopping','backed-up','applying','rollback'):
                raise ValueError('Another core operation is pending')
            policy = managed_state.read(core_deploy.policy_path(root,rejected))
            if not isinstance(policy,dict): raise ValueError('Original core policy snapshot required')
            journal = {'schema':1,'operation':'managed-core-rollback','root':str(root),'attempt':attempt,
                       'previous':previous,'rejected':rejected,'data_identity':identity,
                       'previous_pointer':rejected if state['current']==rejected else state['previous'],
                       'policy_sha256':role_release.json_digest(policy),'phase':'stopping'}
            role_prepare.directory(directory)
            managed_state.persist(path,journal)

        def phase(value):
            nonlocal journal
            journal = {**journal,'phase':value}
            managed_state.persist(path,journal)

        if state['current'] == previous and pending is None:
            if journal['phase'] not in ('starting','committed') or state['previous'] != journal['previous_pointer']:
                raise ValueError('Core rollback pointer changed before its commit')
            recover_committed()
            if journal['phase'] != 'committed': phase('committed')
            return previous
        if journal['phase'] == 'committed':
            raise ValueError('A completed rollback cannot replace a different core pointer')
        expected_pending = {'target':previous,'phase':'managed-rollback'}
        allowed_pending = (None,expected_pending)
        if state['current'] == previous:
            allowed_pending += tuple({'target':rejected,'phase':value} for value in ('stopping','backed-up','applying','rollback'))
        if pending not in allowed_pending: raise ValueError('Another core deployment is pending')
        policy = managed_state.read(core_deploy.policy_path(root,rejected))
        if not isinstance(policy,dict) or role_release.json_digest(policy) != journal['policy_sha256']:
            raise ValueError('Original core policy snapshot changed')
        role_deploy.release_path(root,previous); role_deploy.release_path(root,rejected)
        managed_state.persist(root/'state.json',{**state,'pending':expected_pending})
        resuming_start = journal['phase'] == 'starting'
        if journal['phase'] == 'stopping':
            core_deploy.compose(root,rejected,'stop','synapse','control',execute=execute)
            phase('restoring')
        if journal['phase'] == 'restoring':
            core_deploy.require_backup_idle(root,execute=execute)
            core_deploy.restore_policy(root,previous,rejected,execute=execute)
            phase('starting')
        if resuming_start:
            # Without a committed pointer the previous up may have finished.
            # Stop writers before replaying configure, never write live policy.
            core_deploy.compose(root,previous,'stop','synapse','control',execute=execute)
        core_deploy.start_configured(root,previous,execute=execute)
        check_health(root,previous,execute=execute); verify_identity()
        managed_state.persist(root/'state.json',{'schema':1,'current':previous,'previous':journal['previous_pointer'],
                                              'pending':None,'data_identity':identity})
        phase('committed')
        return previous
