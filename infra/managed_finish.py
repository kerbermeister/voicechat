"""Refresh owned maintenance delegates after a terminal managed release.

The application commit is already forward-only. These idempotent installations
resume their own journals; failure must never roll back user data or containers.
"""
from pathlib import Path

import cohost_tls_bootstrap
import core_backup_bootstrap
import managed_journal
import managed_release
import node_inventory
import role_bootstrap
import shared_update


def finish(root,attempt):
    root=Path(root).absolute()
    journal,baseline,target,_=managed_journal._load(root,attempt)
    if journal['phase'] not in ('complete','rolled-back'):
        raise ValueError('Release all role fences before updating maintenance delegates')
    actual=target if journal['phase']=='complete' else baseline
    core=root/'core'
    role_bootstrap.ready(core,'core')
    managed_release.inspect_role(core,actual['public'],actual['inventory'],actual['core'],subnet=actual['subnet'])
    core_backup_bootstrap.install(core,actual['public'],actual['inventory'],subnet=actual['subnet'])
    cohost=[step['edge_id'] for step in journal['participants'] if step['role']=='edge' and
            node_inventory.shared_tls_profile(actual['inventory'],step['edge_id']) is not None]
    for identifier in cohost:
        edge=root/'edges'/identifier
        role_bootstrap.ready(edge,'edge',identifier)
        managed_release.inspect_role(edge,actual['public'],actual['inventory'],actual['edges'][identifier],subnet=actual['subnet'])
        shared=Path(journal['shared_root'])
        # Source ownership changes only; install refuses a changed renderer and
        # never reloads the neighboring site's serving Caddy configuration.
        shared_update.install(shared)
        cohost_tls_bootstrap.install(shared)
    return {'schema':1,'attempt':attempt,'phase':journal['phase'],'maintenance_ready':True,
            'core_commit':actual['core']['commit'],'scope':journal['request']['scope'],'selected_edges':journal['request']['edges'],
            'edges':{key:manifest['commit'] for key,manifest in actual['edges'].items()}}
