"""Offline role release manifests and conservative partial-release guards.

This is a separate contract from deploy.py's legacy single-host manifest.
It does not install, publish, select a runtime, or modify release pointers.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

import node_inventory
import role_config
from render_roles import bundle
import topology

# Version these together with breaking API/config/storage changes. These are
# release compatibility contracts, not PostgreSQL/Synapse migration numbers.
CONTRACTS = {'route_schema': 1, 'role_config': 1, 'core_api': 1, 'core_storage': 1}
IMAGE = re.compile(r'[a-z0-9][a-z0-9._/:-]*@sha256:[a-f0-9]{64}')
SHA = re.compile(r'[a-f0-9]{64}')


def digest(value):
    return hashlib.sha256(value).hexdigest()


def json_digest(value):
    return digest(json.dumps(value, sort_keys=True, separators=(',', ':')).encode())


def make(public, inventory, role, commit, application_image, edge_id=None, subnet='10.241.0.0/28'):
    files, _ = bundle(public, inventory, role, edge_id, subnet)
    if not isinstance(application_image, str) or not re.fullmatch(r'ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}', application_image):
        raise ValueError('Application image must be an immutable GHCR digest')
    if role == 'core':
        images = {name: role_config.pinned_image(name) for name in ('configure', 'postgres', 'synapse')}
        images['control'] = application_image
        node = inventory['core']
    else:
        compose = json.loads(files['infra/compose.edge.json'])
        images = {name: application_image if name == 'web' else service['image']
                  for name, service in compose['services'].items()}
        node = node_inventory.edge_assignment(inventory, edge_id)
    return validate({'schema': 1, 'role': role, 'edge_id': edge_id,
        'service_id': public['service_id'], 'commit': commit,
        'identity': {'canonical_origin': public['canonical_origin'], 'matrix_server_name': public['matrix_server_name']},
        'contracts': deepcopy(CONTRACTS), 'topology_sha256': json_digest(public),
        'node_sha256': json_digest(node), 'images': images,
        'files': {name: digest(content.encode()) for name, content in files.items()}})


def validate(value):
    topology.fields(value, ('schema', 'role', 'edge_id', 'service_id', 'commit', 'identity', 'contracts',
                            'topology_sha256', 'node_sha256', 'images', 'files'))
    if type(value['schema']) is not int or value['schema'] != 1 or value['role'] not in ('core', 'edge'):
        raise ValueError('Unsupported role release')
    if not isinstance(value['commit'], str) or not re.fullmatch(r'[a-f0-9]{40}', value['commit']):
        raise ValueError('Invalid source revision')
    if not isinstance(value['service_id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', value['service_id']):
        raise ValueError('Invalid service ID')
    if value['role'] == 'core':
        if value['edge_id'] is not None: raise ValueError('Core has no edge ID')
        services = {'configure', 'postgres', 'synapse', 'control'}
    else:
        if not isinstance(value['edge_id'], str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', value['edge_id']):
            raise ValueError('Invalid edge ID')
        services = {'configure', 'ingress', 'web', 'turn', 'route-health'}
    topology.fields(value['identity'], ('canonical_origin', 'matrix_server_name'))
    topology.origin(value['identity']['canonical_origin'])
    topology.hostname(value['identity']['matrix_server_name'])
    topology.fields(value['contracts'], CONTRACTS)
    if any(type(value['contracts'][key]) is not int or value['contracts'][key] != version
           for key, version in CONTRACTS.items()):
        raise ValueError('Unsupported compatibility contract; explicit migration required')
    for name in ('topology_sha256', 'node_sha256'):
        if not isinstance(value[name], str) or not SHA.fullmatch(value[name]):
            raise ValueError('Invalid configuration fingerprint')
    topology.fields(value['images'], services)
    for name, image in value['images'].items():
        if not isinstance(image, str) or not IMAGE.fullmatch(image):
            raise ValueError('Immutable image digest required')
        if name in ('web', 'control') and not image.startswith('ghcr.io/'):
            raise ValueError('Application images must use GHCR')
    files = value['files']
    if not isinstance(files, dict) or not 1 <= len(files) <= 64:
        raise ValueError('Bounded role file manifest required')
    for name, checksum in files.items():
        if not isinstance(name, str): raise ValueError('Invalid file path')
        path = PurePosixPath(name)
        if (path.as_posix() != name or path.is_absolute() or '..' in path.parts or
                not re.fullmatch(r'(infra|prototype)/[a-zA-Z0-9_.-]+', name) or
                not isinstance(checksum, str) or not SHA.fullmatch(checksum)):
            raise ValueError('Invalid role file manifest entry')
    required = {'infra/compose.' + value['role'] + '.json', 'infra/node.json', 'infra/known_hosts'}
    if not required <= files.keys(): raise ValueError('Incomplete role manifest')
    return value


def load(path):
    return validate(topology.read_json(path))


def verify_bundle(release, manifest, public, inventory, subnet='10.241.0.0/28'):
    """Reconstruct the complete expected file set, not just the supplied checksums."""
    validate(manifest)
    role = manifest['role']
    expected = make(public, inventory, role, manifest['commit'],
                    manifest['images']['control' if role == 'core' else 'web'], manifest['edge_id'], subnet)
    if expected != manifest:
        raise ValueError('Release does not match the requested role/configuration/source bundle')
    verify_recorded_bundle(release, manifest)


def verify_recorded_bundle(release, manifest):
    """Recheck a previously verified manifest from private deployment state.

    This cannot establish trust in a new candidate: use verify_bundle for that.
    Old immutable sources need not match the currently installed renderer.
    """
    validate(manifest)
    release = Path(release)
    if release.is_symlink(): raise ValueError('Release root must not be a symlink')
    # Checksums alone do not stop an extra Python module shadowing a standard
    # library import when configure/network scripts execute from this directory.
    source_directories = {Path(name).parent.as_posix() for name in manifest['files']}
    if any(item.name not in source_directories | {'release.json'} for item in release.iterdir()):
        raise ValueError('Unexpected entry in role release')
    for directory in source_directories:
        path = release / directory
        if path.is_symlink() or not path.is_dir():
            raise ValueError('Role source directory is missing or symlinked')
        expected_names = {Path(name).name for name in manifest['files'] if Path(name).parent.as_posix() == directory}
        # Runtime is deliberately outside the immutable source contract. The
        # deployer validates its private shared mount separately.
        allowed = expected_names | ({'runtime'} if directory == 'infra' else set())
        if any(item.name not in allowed for item in path.iterdir()):
            raise ValueError('Unexpected file in role source directory')
    for name, checksum in manifest['files'].items():
        path = release / name
        if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
            raise ValueError('Missing or symlinked role file')
        if digest(path.read_bytes()) != checksum: raise ValueError('Role file checksum mismatch')


def require_compatible(core, edge):
    validate(core); validate(edge)
    if core['role'] != 'core' or edge['role'] != 'edge':
        raise ValueError('Core/edge pair required')
    if any(core[name] != edge[name] for name in ('service_id', 'identity', 'contracts')):
        raise ValueError('Incompatible role releases')
    # Different topology revisions are allowed during a staged catalog update;
    # client/server TURN hosts are deliberately intersected during that interval.


def require_web_only(current, target):
    validate(current); validate(target)
    if current['role'] != 'edge' or target['role'] != 'edge':
        raise ValueError('Web-only needs an existing edge baseline')
    before, after = deepcopy(current), deepcopy(target)
    for value in (before, after):
        value.pop('commit')
        value['images'].pop('web')
    if before != after:
        raise ValueError('Web-only cannot change role sources/configuration, host or other images')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--role', choices=('core', 'edge'), required=True)
    parser.add_argument('--edge')
    parser.add_argument('--image', required=True)
    parser.add_argument('--edge-subnet', default='10.241.0.0/28')
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    # A release commit must describe the actual source, including new files.
    if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=role_config.ROOT):
        raise SystemExit('Commit the reviewed source before preparing a release manifest')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=role_config.ROOT, text=True).strip()
    public = topology.load(args.topology)
    inventory = node_inventory.load(args.inventory, public)
    manifest = make(public, inventory, args.role, commit, args.image, args.edge, args.edge_subnet)
    verify_bundle(args.bundle, manifest, public, inventory, args.edge_subnet)
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        output.write(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    print('Role manifest verified and written locally; nothing deployed or published.')


if __name__ == '__main__':
    main()
