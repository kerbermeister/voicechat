"""Roll back an owned edge using its exact recorded bundle, not today's renderer."""
from pathlib import Path
import subprocess

import edge_deploy
import managed_state
import role_bootstrap
import role_deploy
import role_prepare
import role_release
import topology


def rollback(root, public, inventory, previous_manifest, rejected_manifest, attempt, *,
             scope='edge', subnet='10.241.0.0/28', execute=role_deploy.run,
             check_network=edge_deploy.network_ready, check_health=edge_deploy.healthy,
             check_boot=role_bootstrap.ready, activate_monitor=role_bootstrap.activate):
    root = Path(root).absolute()
    if root.resolve() != root or scope not in ('web','edge'):
        raise ValueError('Canonical edge root and web/edge rollback scope required')
    if not isinstance(attempt,str) or not role_release.SHA.fullmatch(attempt):
        raise ValueError('Owned managed rollback attempt required')
    for manifest in (previous_manifest,rejected_manifest):
        role_release.verify_configuration(manifest,public,inventory)
        if manifest['role'] != 'edge': raise ValueError('Edge rollback requires edge manifests')
    if any(previous_manifest[key] != rejected_manifest[key] for key in
           ('edge_id','service_id','identity','contracts','node_sha256','topology_sha256')):
        raise ValueError('Edge rollback cannot change installation or host')
    if scope == 'web': role_release.require_web_only(previous_manifest,rejected_manifest)
    previous = edge_deploy.record_for(public,inventory,previous_manifest)
    rejected = edge_deploy.record_for(public,inventory,rejected_manifest)
    edge_id = previous_manifest['edge_id']
    with role_bootstrap.monitor_after(root,'edge',edge_id,activate=activate_monitor), managed_state.locked(root), \
            check_network(inventory,edge_id,subnet,execute=execute):
        role_deploy.require_rollout_owner(root,attempt,previous_manifest)
        check_boot(root,'edge',edge_id)
        role_deploy.release_path(root,previous); role_deploy.release_path(root,rejected)
        state = edge_deploy.read_state(root,edge_id)
        if state['current'] not in (previous,rejected):
            raise ValueError('Edge rollback baseline changed')
        directory = root / 'runtime/edge-deploy'
        if directory.exists() or directory.is_symlink(): role_prepare.directory(directory)
        path = directory / ('rollback-' + attempt + '.json')
        exists = path.exists() or path.is_symlink()
        pending = state['pending']
        with managed_state.locked(root/'runtime/tls'):
            for service in ('web','turn'): edge_deploy.certificate(root,previous,service)
            def up():
                if scope == 'edge':
                    # Do not regenerate the shared TURN config while its reader
                    # is running; explicitly wait for the one-shot writer.
                    edge_deploy.compose(root,previous,'stop','turn',execute=execute)
                    edge_deploy.compose(root,previous,'up','-d','--no-deps','configure',execute=execute)
                    edge_deploy.compose(root,previous,'wait','configure',execute=execute)
                services = ['web'] if scope == 'web' else [name for name in
                    ('route-health','web','turn','ingress') if name in previous_manifest['images']]
                edge_deploy.compose(root,previous,'up','-d','--no-deps','--wait','--wait-timeout','180',*services,execute=execute)
                check_health(root,previous,execute=execute)
            def recover():
                try: check_health(root,previous,execute=execute)
                except (ValueError,OSError,RuntimeError,subprocess.SubprocessError): up()
            if not exists and state['current'] == previous:
                if pending is None:
                    recover(); return previous
                if pending['target'] != rejected or pending['scope'] != scope or pending['phase'] == 'managed-rollback':
                    raise ValueError('Another edge deployment is pending')
                if pending['phase'] == 'prepared':
                    recover()
                    managed_state.persist(root/'state.json',{**state,'pending':None})
                    return previous
            if exists:
                journal = managed_state.read(path)
                topology.fields(journal,('schema','operation','root','attempt','previous','rejected','scope','previous_pointer','phase'))
                if (type(journal['schema']) is not int or journal['schema'] != 1 or
                        journal['operation'] != 'managed-edge-rollback' or journal['root'] != str(root) or
                        journal['attempt'] != attempt or journal['previous'] != previous or journal['rejected'] != rejected or
                        journal['scope'] != scope or journal['phase'] not in ('applying','committed')):
                    raise ValueError('Resume the same valid managed edge rollback')
                if journal['previous_pointer'] is not None: edge_deploy.validate_record(journal['previous_pointer'],edge_id)
            else:
                if state['current'] == rejected:
                    if pending is not None or state['previous'] != previous:
                        raise ValueError('Rejected edge has another previous/pending release')
                elif (pending is None or pending['target'] != rejected or pending['scope'] != scope or
                      pending['phase'] not in ('applying','rollback')):
                    raise ValueError('Another edge operation is pending')
                journal = {'schema':1,'operation':'managed-edge-rollback','root':str(root),'attempt':attempt,
                           'previous':previous,'rejected':rejected,'scope':scope,
                           'previous_pointer':rejected if state['current']==rejected else state['previous'],'phase':'applying'}
                role_prepare.directory(directory); managed_state.persist(path,journal)
            if state['current'] == previous and pending is None:
                if state['previous'] != journal['previous_pointer']:
                    raise ValueError('Edge rollback pointer changed before its commit')
                recover()
            else:
                if journal['phase'] == 'committed': raise ValueError('Completed edge rollback pointer changed')
                expected = {'target':previous,'scope':scope,'phase':'managed-rollback'}
                allowed = (None,expected)
                if state['current'] == previous:
                    allowed += tuple({'target':rejected,'scope':scope,'phase':value} for value in ('applying','rollback'))
                if pending not in allowed: raise ValueError('Another edge deployment is pending')
                before = edge_deploy.snapshot(root,previous,execute=execute) if scope == 'web' else None
                managed_state.persist(root/'state.json',{**state,'pending':expected})
                up()
                if before is not None and edge_deploy.snapshot(root,previous,execute=execute) != before:
                    raise RuntimeError('Web rollback changed another edge service')
                managed_state.persist(root/'state.json',{'schema':1,'current':previous,
                    'previous':journal['previous_pointer'],'pending':None})
            managed_state.persist(path,{**journal,'phase':'committed'})
            return previous
