"""Bounded, frozen-source SSH entry for one managed role operation.

No secrets arrive on stdin. The operation is bound to its delivered public
sources until its maintenance receipt is released; retries are serialized.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import sys

import core_deploy
import managed_apply
import managed_core_rollback
import managed_edge_rollback
import managed_fence
import managed_release
import managed_state
import role_prepare
import edge_deploy
import release_delivery
import role_deploy
import role_bootstrap
import role_config
import role_release
import topology

MAX_INPUT=65536
OPERATIONS=('preflight','claim','apply','observe','rollback','release')


def request(raw):
    if len(raw)>MAX_INPUT: raise ValueError('Managed peer input is too large')
    value=json.loads(raw.decode('utf-8'),object_pairs_hook=topology.unique_object)
    topology.fields(value,('schema','operation','public','inventory','subnet','before','target',
                           'attempt','scope','core','data_identity','manifest'))
    if type(value['schema']) is not int or value['schema']!=1 or value['operation'] not in OPERATIONS:
        raise ValueError('Known managed peer operation required')
    for manifest in (value['before'],value['target']):
        role_release.verify_configuration(manifest,value['public'],value['inventory'])
    before,target=value['before'],value['target']
    if any(before[key]!=target[key] for key in
           ('role','edge_id','service_id','identity','contracts','node_sha256','topology_sha256')):
        raise ValueError('Normal role operation cannot change its host or identity')
    if not isinstance(value['attempt'],str) or not role_release.SHA.fullmatch(value['attempt']):
        raise ValueError('Managed attempt required')
    # Validate the edge subnet using the existing renderer without comparing
    # today's source files with historical before bundles.
    for edge in value['public']['edges']:
        role_config.edge(value['public'],value['inventory'],edge['id'],value['subnet'])
    if target['role']=='core':
        if value['scope'] is not None or value['core'] is not None: raise ValueError('Core operation has no edge inputs')
        core_deploy.validate_data_identity(value['data_identity'])
    else:
        if value['scope'] not in ('web','edge') or value['data_identity'] is not None:
            raise ValueError('Edge operation requires web/edge scope without core data')
        if value['scope']=='web': role_release.require_web_only(before,target)
        if value['core'] is not None: role_release.require_compatible(value['core'],target)
        if value['operation']=='apply' and value['core'] is None: raise ValueError('Apply requires the actual core baseline')
    if value['operation'] in ('observe','release'):
        if value['manifest'] not in (before,target): raise ValueError('Observe/release only this operation manifests')
    elif value['manifest'] is not None: raise ValueError('This operation does not take an observation manifest')
    return value


def operate(value,root,source_sha,*,source=None):
    root=Path(root).absolute()
    source=Path(source) if source is not None else Path(__file__).resolve().parents[1]
    if (not isinstance(source_sha,str) or not release_delivery.SHA.fullmatch(source_sha) or
            root.resolve()!=root or not re.fullmatch(r'/[A-Za-z0-9/_-]+',str(root)) or root==Path('/') or
            source!=root/'bundles'/source_sha or source.resolve()!=source):
        raise ValueError('Exact immutable managed source and canonical root required')
    delivery=release_delivery.decode(release_delivery.read(source/'delivery.json'))
    if delivery['archive_sha256']!=source_sha: raise ValueError('Source delivery identity changed')
    release_delivery.verify(source,delivery)
    if platform.system()!='Linux' or os.geteuid()!=0: raise ValueError('Managed peer requires its pinned Linux host as root')
    sockets=('unix:///var/run/docker.sock','unix:///run/docker.sock')
    if os.environ.get('DOCKER_HOST') not in (None,'',*sockets): raise ValueError('Local rootful Docker required')
    endpoint=role_deploy.run(['docker','context','inspect','--format','{{(index .Endpoints "docker").Host}}']).decode().strip()
    if endpoint not in sockets: raise ValueError('Local rootful Docker required')
    before,target=value['before'],value['target'];attempt=value['attempt']
    if delivery['manifest']['origin']!=value['public']['canonical_origin']:
        raise ValueError('Source candidate belongs to another origin')
    if target!=before:
        candidate=delivery['manifest']
        expected=role_release.make(value['public'],value['inventory'],target['role'],candidate['commit'],
            candidate['control' if target['role']=='core' else 'web'],target['edge_id'],value['subnet'])
        if target!=expected: raise ValueError('Role target differs from its frozen source delivery')
    role_root=root/'core' if target['role']=='core' else root/'edges'/target['edge_id']
    managed_fence._parameters(role_root,value['public'],value['inventory'],before,target,attempt,Path('/'))
    common={'subnet':value['subnet']}
    arguments=(role_root,value['public'],value['inventory'],before,target)
    if value['operation']=='preflight':
        facts=managed_release.inspect_role(role_root,value['public'],value['inventory'],before,**common)
        # Stage immutable sources/images on every host before the first fence.
        # Runtime, secrets, service processes and release pointers are untouched.
        role_prepare.prepare(role_root,value['public'],value['inventory'],target,value['subnet'])
        module=core_deploy if target['role']=='core' else edge_deploy
        record=(core_deploy.record_for(role_root,value['inventory'],target) if target['role']=='core' else
                edge_deploy.record_for(value['public'],value['inventory'],target))
        module.compose(role_root,record,'pull','--policy','missing',
                       *(['web'] if value['scope']=='web' else []))
        return {'facts':facts,'fence':None}
    with managed_state.locked(role_root/'runtime/managed-peer') as directory:
        path=directory/'current.json'
        binding={'schema':1,'attempt':attempt,'source':source_sha,'before':role_release.json_digest(before),
                 'target':role_release.json_digest(target),'scope':value['scope']}
        if path.exists() or path.is_symlink():
            old=managed_state.read(path)
            topology.fields(old,('schema','attempt','source','before','target','scope'))
            if (type(old['schema']) is not int or old['schema']!=1 or old['scope'] not in (None,'web','edge') or
                    any(not isinstance(old[key],str) or not role_release.SHA.fullmatch(old[key])
                        for key in ('attempt','source','before','target'))):
                raise ValueError('Valid frozen peer source receipt required')
            if old!=binding:
                intent=role_deploy.managed_operation(role_root)
                if intent is None or intent['phase']!='released' or intent['attempt']!=old.get('attempt') or old.get('attempt')==attempt:
                    raise ValueError('Resume the same frozen peer source before another operation')
                archive=directory/(old['attempt']+'.json')
                if archive.exists() or archive.is_symlink():
                    if managed_state.read(archive)!=old: raise ValueError('Peer source archive differs from previous receipt')
                # Persist before replacement: a lost reply resumes either source
                # using the already released receipt, without replaying apps.
                managed_state.persist(archive,old)
        managed_state.persist(path,binding)
        operation=value['operation']
        if operation=='claim': return managed_fence.claim(*arguments,attempt,**common)
        if operation=='apply':
            return managed_apply.apply(*arguments,attempt,scope=value['scope'],core_manifest=value['core'],**common)
        manifest=value['manifest']
        if operation=='rollback':
            managed_fence.retarget(*arguments,before,attempt)
            # A failure may precede apply's operator installation. The old
            # monitor is now quiescent under the retargeted owned fence.
            role_bootstrap.install(role_root,target['role'],target['edge_id'])
            if target['role']=='core':
                managed_core_rollback.rollback(*arguments,value['data_identity'],attempt,**common)
            else: managed_edge_rollback.rollback(*arguments,attempt,scope=value['scope'],**common)
            manifest=before
        function=managed_fence.release if operation=='release' else managed_fence.observe
        return function(*arguments,manifest,attempt,**common)


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
