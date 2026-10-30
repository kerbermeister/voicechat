"""Verified CI entry point for the one-time, journaled cohost transition.

Public source delivery is immutable. Deployment inputs arrive on private SSH
stdin; signing keys, runtime secrets and registry credentials are never inputs.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys

import initial_cohost
import node_inventory
import release_delivery
import route_catalog
import topology
import tunnel_config
import role_config

MAX_INPUT=65536


def request(raw):
    if len(raw)>MAX_INPUT:raise ValueError('Initial deployment inputs are too large')
    value=json.loads(raw.decode('utf-8'),object_pairs_hook=topology.unique_object)
    topology.fields(value,('schema','root','legacy_root','shared_root','public','inventory',
                           'subnet','catalog','catalog_key'))
    if type(value['schema']) is not int or value['schema']!=1:raise ValueError('Known initial request required')
    paths=[]
    for name in ('root','legacy_root','shared_root'):
        path=value[name]
        if (not isinstance(path,str) or not re.fullmatch(r'/[A-Za-z0-9/_-]+',path) or
                str(Path(path))!=path or '..' in path.split('/') or path=='/'):
            raise ValueError('Canonical initial installation paths required')
        paths.append(Path(path))
    if len(set(paths))!=3 or any(left in right.parents for left in paths for right in paths if left!=right):
        raise ValueError('Distinct nonnested installation roots required')
    topology.validate(value['public']);node_inventory.validate(value['inventory'],value['public'])
    edges=value['inventory']['edges']
    if (set(tunnel_config.physical_nodes(value['inventory']))!={'core'} or len(edges)!=1 or
            edges[0].get('host')!='core' or not edges[0].get('legacy_turn') or
            node_inventory.shared_tls_profile(value['inventory'],edges[0]['id']) is None or
            value['public']['edges'][0]['origin']!=value['public']['canonical_origin']):
        raise ValueError('Initial deployment requires one canonical cohost edge with shared TLS and legacy TURN')
    role_config.edge(value['public'],value['inventory'],edges[0]['id'],value['subnet'])
    envelope=json.dumps(value['catalog'],separators=(',',':')).encode()
    verified=route_catalog.verify(envelope,value['catalog_key'],value['public'])
    if verified.topology!=value['public']:raise ValueError('Catalog must publish the exact prepared topology')
    return value


def environment():
    config=os.environ.get('SERVER_ROLE_CONFIG','')
    catalog=os.environ.get('SIGNED_ROUTE_CATALOG','')
    if not config or not catalog:raise ValueError('Configure SERVER_ROLE_CONFIG and SIGNED_ROUTE_CATALOG first')
    if len(config.encode())+len(catalog.encode())>MAX_INPUT:raise ValueError('Initial environment inputs are too large')
    value=json.loads(config,object_pairs_hook=topology.unique_object)
    topology.fields(value,('schema','root','legacy_root','shared_root','public','inventory','subnet'))
    result=request(json.dumps({**value,'catalog':json.loads(catalog,object_pairs_hook=topology.unique_object),
        'catalog_key':os.environ.get('CLIENT_ROUTE_CATALOG_KEY','')}).encode())
    if result['public']['canonical_origin']!=os.environ.get('PUBLIC_URL'):
        raise ValueError('Server and compiled client origins differ')
    return result


def deploy(raw,root,source_sha,*,source=None,retry=False):
    value=request(raw)
    root=Path(root).absolute()
    source=Path(source) if source is not None else Path(__file__).resolve().parents[1]
    if (not release_delivery.SHA.fullmatch(source_sha) or root.resolve()!=root or
            value['root']!=str(root) or source!=root/'bundles'/source_sha or source.resolve()!=source):
        raise ValueError('Use the exact immutable delivery at the requested managed root')
    record=release_delivery.decode(release_delivery.read(source/'delivery.json'))
    if record['archive_sha256']!=source_sha:raise ValueError('Source delivery identity changed')
    release_delivery.verify(source,record)
    if platform.system()!='Linux' or os.geteuid()!=0:raise ValueError('Initial deployment requires the selected Linux host as root')
    for name in ('docker','openssl','wg','wg-quick','nft','ip','systemctl'):
        if shutil.which(name) is None:raise ValueError('Provision the required host tool first: '+name)
    current=initial_cohost.migrate(root,Path(value['legacy_root']),Path(value['shared_root']),
        value['public'],value['inventory'],record['manifest'],
        json.dumps(value['catalog'],separators=(',',':')).encode(),value['catalog_key'],
        backend_sha256=record['backend'],subnet=value['subnet'],retry=retry)
    # The full current record stays on A; never print runtime or database details.
    return {'schema':1,'kind':'roles','root':str(root),
            'commit':record['manifest']['commit'],'target':initial_cohost.role_release.json_digest(current['target'])}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-environment',action='store_true')
    parser.add_argument('--root',type=Path)
    parser.add_argument('--source-sha')
    parser.add_argument('--retry',action='store_true')
    args=parser.parse_args()
    if args.check_environment:
        if args.root is not None or args.source_sha is not None or args.retry:parser.error('Choose validation or deployment')
        environment();return
    if args.root is None or args.source_sha is None:parser.error('Deployment requires root and source SHA')
    print(json.dumps(deploy(sys.stdin.buffer.read(MAX_INPUT+1),args.root,args.source_sha,retry=args.retry)))


if __name__=='__main__':main()
