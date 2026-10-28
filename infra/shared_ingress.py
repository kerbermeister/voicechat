"""Reviewable config for the existing Avito Caddy before shared port cutover.

These renderers do not install a manager or change a live deployment. Adoption
must verify the current Caddy image/config/volumes before using this override.
"""
from pathlib import PurePosixPath
from pathlib import Path
import hashlib
import re
from urllib.parse import urlsplit

import node_inventory
import topology

CADDY_IMAGE = 'caddy@sha256:226d1f059b75399fe19182893c7184591c07b97afc8dfcf44eeb80c9a77a530f'


def absolute_path(value):
    if not isinstance(value, str): raise ValueError('Deployment path must be text')
    path = PurePosixPath(value)
    if (path.as_posix() != value or not path.is_absolute() or
            '..' in path.parts or not re.fullmatch(r'/[A-Za-z0-9_./-]+', value)):
        raise ValueError('Canonical absolute ASCII deployment path required')
    return value


def legacy_config(business_routes, public):
    topology.validate(public)
    origin = urlsplit(public['canonical_origin'])
    if origin.scheme != 'https' or origin.port not in (None, 443):
        raise ValueError('Legacy ingress requires a standard HTTPS origin')
    if (not isinstance(business_routes, str) or not business_routes.strip() or
            len(business_routes.encode()) > 65536 or '\0' in business_routes or
            origin.hostname in business_routes):
        raise ValueError('Reviewed business routes without previous VoiceChat routes required')
    return business_routes.rstrip() + f'''

{origin.hostname} {{
    header >Alt-Svc clear
    reverse_proxy voicechat-web:80
}}
'''


def compose_override(config_directory, *, shared=None):
    config_directory = absolute_path(config_directory)
    if shared is not None: node_inventory.shared_tls(shared)
    # Compose !override is essential: a retained leaf mount could hide the new
    # Caddyfile in the directory, and retained :443 would collide with the front.
    result = f'''services:
  caddy:
    image: {CADDY_IMAGE}
    ports: !override
      - "80:80"
'''
    if shared is None: result += '      - "443:443"\n'
    result += f'''    volumes: !override
      - type: bind
        source: {config_directory}
        target: /etc/caddy
        read_only: true
        bind:
          create_host_path: false
      - caddy_data:/data
      - caddy_config:/config
'''
    if shared is not None:
        result += f'''    networks:
      default: {{}}
      shared-tls:
        ipv4_address: {shared['legacy_ip']}
networks:
  shared-tls:
    external: true
    name: {shared['network']}
'''
    return result


def compose_environment(repo, override):
    return 'COMPOSE_FILE=' + absolute_path(repo) + '/deploy/docker-compose.yml:' + absolute_path(override) + '\n'


def stage(root, repo, edge_root, public, inventory, edge_id, business_routes, *, mode='legacy', system_root=Path('/')):
    """Stage an immutable plan/package; leave Caddy, .env and Git untouched.

    A later adoption controller must verify the existing host and activate the
    plan. Merely preparing it does not claim ownership of the running Caddy.
    """
    import edge_config
    import managed_state
    import network_bootstrap
    import role_bootstrap
    import role_prepare
    import role_release
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Shared ingress root must not traverse symlinks')
    repo, edge_root = absolute_path(str(repo)), Path(absolute_path(str(edge_root)))
    node_inventory.validate(inventory, public)
    entry = next((item for item in inventory['edges'] if item['id'] == edge_id), None)
    if entry is None or entry.get('host') != 'core': raise ValueError('Shared manager requires a co-located edge')
    if mode not in ('legacy', 'shared'): raise ValueError('Unknown shared ingress mode')
    profile = entry.get('shared_tls') if mode == 'shared' else None
    if mode == 'shared' and profile is None: raise ValueError('Shared TLS profile required before cutover')
    configuration = (edge_config.shared_legacy_proxy(business_routes, public, edge_id, profile['ingress_ip'])
                     if profile else legacy_config(business_routes, public))
    _, code, contents, _, operator = role_bootstrap.plan(edge_root, 'edge', edge_id)
    target = {'schema': 1, 'repo': repo, 'edge_root': str(edge_root), 'edge_id': edge_id,
              'mode': mode, 'public': public, 'node': inventory['core'], 'shared_tls': profile,
              'operator': operator}
    files = {'Caddyfile': configuration.encode(), 'compose.override.yaml':
             compose_override(str(root / 'runtime/caddy'), shared=profile).encode(),
             'compose.env-line': compose_environment(repo, str(root / 'runtime/compose.override.yaml')).encode()}
    record = {'schema': 1, 'target': target,
              'files': {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}}
    with managed_state.locked(root):
        role_prepare.directory(root / 'plans')
        plan = root / 'plans' / role_release.json_digest(record)
        role_prepare.directory(plan)
        if {item.name for item in plan.iterdir()} - (set(files) | {'plan.json'}):
            raise ValueError('Unexpected shared ingress plan file')
        for name, content in files.items():
            if network_bootstrap.existing(plan / name) not in (None, content):
                raise ValueError('Shared ingress plan changed')
        manifest = plan / 'plan.json'
        if (manifest.exists() or manifest.is_symlink()) and managed_state.read(manifest) != record:
            raise ValueError('Shared ingress plan manifest changed')
        role_bootstrap.install_sources(Path(system_root).resolve(), code, contents)
        role_bootstrap.verify_record(Path(system_root).resolve(), operator)
        for name, content in files.items():
            if network_bootstrap.existing(plan / name) is None:
                network_bootstrap.create_file(plan / name, content)
        managed_state.persist(manifest, record)
    return plan
