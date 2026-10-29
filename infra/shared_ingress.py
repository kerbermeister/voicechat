"""Reviewable config for the existing Avito Caddy before shared port cutover.

These renderers do not install a manager or change a live deployment. Adoption
must verify the current Caddy image/config/volumes before using this override.
"""
from pathlib import PurePosixPath
from pathlib import Path
import hashlib
import json
import os
import re
import stat
import tempfile
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


def read_plan(root, plan, *, system_root=Path('/')):
    """Recheck a staged plan under the caller's shared ingress lock."""
    import managed_state
    import network_bootstrap
    import role_bootstrap
    import role_release
    root, plan = Path(root).absolute(), Path(plan).absolute()
    if root.resolve() != root or plan.resolve() != plan or plan.parent != root / 'plans':
        raise ValueError('Immutable plan must belong to this shared ingress root')
    info = plan.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError('Shared ingress plan must be an owned private directory')
    record = managed_state.read(plan / 'plan.json')
    topology.fields(record, ('schema', 'target', 'files'))
    if type(record['schema']) is not int or record['schema'] != 1 or role_release.json_digest(record) != plan.name:
        raise ValueError('Shared ingress plan identity changed')
    target = record['target']
    topology.fields(target, ('schema', 'repo', 'edge_root', 'edge_id', 'mode', 'public', 'node', 'shared_tls', 'operator'))
    if type(target['schema']) is not int or target['schema'] != 1 or target['mode'] not in ('legacy', 'shared'):
        raise ValueError('Unsupported shared ingress target')
    public = topology.validate(target['public'])
    node_inventory.validate({'schema': 1, 'service_id': public['service_id'], 'ssh_user': 'root',
        'ssh_port': 22, 'core': target['node'], 'edges': [{'id': target['edge_id'], 'host': 'core'}]})
    if target['edge_id'] not in {edge['id'] for edge in public['edges']}:
        raise ValueError('Shared edge is absent from its topology')
    absolute_path(target['repo']); absolute_path(target['edge_root'])
    if target['mode'] == 'shared': node_inventory.shared_tls(target['shared_tls'])
    elif target['shared_tls'] is not None: raise ValueError('Legacy plan cannot claim a shared bridge')
    expected = role_bootstrap.plan(Path(target['edge_root']), 'edge', target['edge_id'])[4]
    if target['operator'] != expected: raise ValueError('Restage the plan with the reviewed operator sources')
    role_bootstrap.verify_record(Path(system_root).resolve(), target['operator'])
    names = {'Caddyfile', 'compose.override.yaml', 'compose.env-line'}
    topology.fields(record['files'], names)
    if {item.name for item in plan.iterdir()} != names | {'plan.json'}:
        raise ValueError('Shared ingress plan source set changed')
    files = {}
    for name, checksum in record['files'].items():
        content = network_bootstrap.existing(plan / name)
        if content is None or len(content) > 131072 or hashlib.sha256(content).hexdigest() != checksum:
            raise ValueError('Shared ingress plan file changed')
        files[name] = content
    return target, files


def read_environment(path):
    # Existing legacy .env may be 0644. Reject writers/symlinks and keep its
    # complete bytes server-local; a later managed replacement will use 0600.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('Deployment environment must be an owned regular file')
        content = source.read(65537)
    if len(content) > 65536: raise ValueError('Deployment environment is too large')
    return content


def compose_config(repo, environment, *files, execute):
    # Match the existing workflow's `cd deploy`, including dotenv ${PWD}, while
    # never parsing secrets ourselves or exposing them in process arguments.
    command = ['docker', 'compose', '--project-directory', str(repo / 'deploy'), '--env-file', str(environment)]
    for path in files: command += ['-f', str(path)]
    process_env = {**os.environ, 'PWD': str(repo / 'deploy')}
    return json.loads(execute([*command, 'config', '--format', 'json'], env=process_env))


def snapshot(projects, *, excluding=(), execute):
    identifiers = set()
    for project in sorted(set(projects)):
        identifiers.update(execute(['docker', 'ps', '-q', '--no-trunc', '--filter',
                                   'label=com.docker.compose.project=' + project]).decode().split())
    identifiers.difference_update(excluding)
    if any(not re.fullmatch(r'[a-f0-9]{64}', value) for value in identifiers):
        raise ValueError('Unexpected neighboring container identity')
    if not identifiers: return []
    rows = execute(['docker', 'inspect', '--format', '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}',
                    *sorted(identifiers)]).decode().splitlines()
    if len(rows) != len(identifiers) or {row.split()[0] for row in rows} != identifiers:
        raise ValueError('Neighboring containers changed during inspection')
    return sorted(rows)


def inspect_legacy_plan(root, plan, *, execute=None, system_root=Path('/')):
    """Read-only deployment preflight; return fingerprints, never .env values.

    Only a disposable parser container is run. No Caddy reload, Git checkout,
    environment replacement or application readiness is claimed by this step.
    """
    import managed_state
    import network_bootstrap
    if execute is None:
        from role_deploy import run
        execute = run
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir(): raise ValueError('Prepared canonical shared ingress root required')
    with managed_state.locked(root):
        target, files = read_plan(root, plan, system_root=system_root)
        if target['mode'] != 'legacy': raise ValueError('Initial adoption requires a legacy plan')
        key = network_bootstrap.existing(Path(system_root) / 'etc/ssh/ssh_host_ed25519_key.pub')
        if key is None or node_inventory.host_key(' '.join(key.decode().split()[:2])) != target['node']['ssh_host_key']:
            raise ValueError('Shared ingress plan belongs to another SSH host')
        repo = Path(target['repo'])
        if repo.resolve() != repo or not repo.is_dir(): raise ValueError('Canonical existing business repository required')
        info = repo.stat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('Business repository must have the deployment owner and no foreign writers')
        git = ['git', '--no-pager', '-C', str(repo)]
        if Path(execute([*git, 'rev-parse', '--show-toplevel']).decode().strip()) != repo:
            raise ValueError('Business Git root changed')
        if execute([*git, 'branch', '--show-current']).strip() != b'main': raise ValueError('Business main branch required')
        head = execute([*git, 'rev-parse', 'HEAD']).decode().strip()
        if not re.fullmatch(r'[a-f0-9]{40}', head): raise ValueError('Invalid business source revision')
        changed = execute([*git, 'diff', '--no-ext-diff', '--name-only', 'HEAD', '--']).decode().splitlines()
        if set(changed) - {'deploy/Caddyfile'}: raise ValueError('Unrelated tracked business changes must be preserved')
        execute([*git, 'diff', '--cached', '--quiet'])
        business = execute([*git, 'show', head + ':deploy/Caddyfile']).decode()
        if legacy_config(business, target['public']).encode() != files['Caddyfile']:
            raise ValueError('Staged legacy config does not match the reviewed business revision')
        environment = repo / 'deploy/.env'
        original = read_environment(environment)
        with tempfile.TemporaryDirectory(prefix='voicechat-shared-inspect-') as temporary:
            temporary = Path(temporary)
            private_env = temporary / 'snapshot.env'
            private_env.write_bytes(original); private_env.chmod(0o600)
            base = repo / 'deploy/docker-compose.yml'
            config = compose_config(repo, private_env, base, execute=execute)
            probe = temporary / 'env-probe.json'
            probe.write_text(json.dumps({'services': {'inspect': {'image': CADDY_IMAGE, 'environment': {
                'VC_COMPOSE_FILE': '${COMPOSE_FILE-}', 'VC_SEPARATOR': '${COMPOSE_PATH_SEPARATOR-}'}}}}))
            resolved = compose_config(repo, private_env, probe, execute=execute)['services']['inspect']['environment']
            if resolved['VC_COMPOSE_FILE'] or resolved['VC_SEPARATOR'] not in ('', ':'):
                raise ValueError('Existing Compose file ownership or path separator requires explicit migration')
            project = config['name']
            if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', project): raise ValueError('Unexpected business project name')
            service = config['services']['caddy']
            domain = topology.hostname(service['environment']['DOMAIN'])
            reserved = {urlsplit(origin).hostname for origin in target['public']['web_origins']}
            reserved.update(edge['turn_host'] for edge in target['public']['edges'])
            reserved.update(urlsplit(edge['origin']).hostname for edge in target['public']['edges'])
            reserved.add(urlsplit(target['public']['canonical_origin']).hostname)
            if domain in reserved:
                raise ValueError('Business and VoiceChat hostnames must remain separate')
            ids = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter',
                'label=com.docker.compose.project=' + project, '--filter', 'label=com.docker.compose.service=caddy']).decode().split()
            if len(ids) != 1 or not re.fullmatch(r'[a-f0-9]{64}', ids[0]): raise ValueError('One existing Caddy container required')
            template = ('{"id":{{json .Id}},"image_id":{{json .Image}},"running":{{json .State.Running}},'
                '"started":{{json .State.StartedAt}},"restarts":{{json .RestartCount}},"mounts":{{json .Mounts}},'
                '"ports":{{json .HostConfig.PortBindings}},"restart":{{json .HostConfig.RestartPolicy}},'
                '"networks":{{json .NetworkSettings.Networks}}}')
            current = json.loads(execute(['docker', 'inspect', '--format', template, ids[0]]))
            pinned = execute(['docker', 'image', 'inspect', '--format', '{{.Id}}', CADDY_IMAGE]).decode().strip()
            if current['id'] != ids[0] or not re.fullmatch(r'sha256:[a-f0-9]{64}', pinned) or current['image_id'] != pinned or not current['running']:
                raise ValueError('Running Caddy does not use the reviewed pinned binary')
            if current['restart']['Name'] != 'unless-stopped' or service.get('restart') != 'unless-stopped':
                raise ValueError('Unrelated Caddy restart policy must remain available')
            expected_ports = {(80, '80', 'tcp'), (443, '443', 'tcp')}
            if {(item['target'], str(item['published']), item.get('protocol', 'tcp')) for item in service['ports']} != expected_ports:
                raise ValueError('Unexpected existing Caddy ports')
            if any(item.get('host_ip', '') not in ('', '0.0.0.0', '::') for item in service['ports']):
                raise ValueError('Do not widen existing Caddy interface bindings')
            if set(current['ports']) != {'80/tcp', '443/tcp'} or any(not bindings or any(
                    item['HostPort'] != port.split('/')[0] or item['HostIp'] not in ('', '0.0.0.0', '::')
                    for item in bindings) for port, bindings in current['ports'].items()):
                raise ValueError('Running Caddy port ownership changed')
            mounts = {item['Destination']: item for item in current['mounts']}
            if set(mounts) != {'/etc/caddy/Caddyfile', '/data', '/config'}:
                raise ValueError('Unknown Caddy mounts must not be removed')
            source = repo / 'deploy/Caddyfile'
            declared = {item['target']: item for item in service['volumes']}
            if set(declared) != set(mounts):
                raise ValueError('Business source Caddy mounts differ from the legacy contract')
            definition, mounted = declared['/etc/caddy/Caddyfile'], mounts['/etc/caddy/Caddyfile']
            if definition['type'] != 'bind' or definition['source'] != str(source) or not definition.get('read_only'):
                raise ValueError('Business source Caddyfile mount changed')
            if mounted['Type'] != 'bind' or mounted['RW'] or mounted['Source'] != str(source):
                raise ValueError('Existing Caddyfile mount changed')
            for name, destination in (('caddy_data', '/data'), ('caddy_config', '/config')):
                definition, mounted = declared[destination], mounts[destination]
                if (definition['type'] != 'volume' or definition['source'] != name or definition.get('read_only') or
                        mounted['Type'] != 'volume' or mounted['Name'] != config['volumes'][name]['name'] or not mounted['RW']):
                    raise ValueError('Existing Caddy data volume identity changed')
            if set(current['networks']) != {config['networks'][name]['name'] for name in service['networks']}:
                raise ValueError('Unknown Caddy network attachments must not be discarded')
            def adapt(content, name):
                path = temporary / name; path.write_bytes(content)
                return json.loads(execute(['docker', 'run', '--rm', '--network', 'none', '--env', 'DOMAIN=' + domain,
                    '--volume', str(path) + ':/etc/caddy/Caddyfile:ro', CADDY_IMAGE,
                    'caddy', 'adapt', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile']))
            host = network_bootstrap.existing(source)
            if host is None: raise ValueError('Existing business Caddyfile is missing')
            candidate = adapt(files['Caddyfile'], 'candidate.Caddyfile')
            existing = candidate if host == files['Caddyfile'] else adapt(host, 'existing.Caddyfile')
            active = json.loads(execute(['docker', 'exec', ids[0], 'wget', '-q', '-O', '-', '-T', '5', '-Y', 'off',
                                        'http://127.0.0.1:2019/config/']))
            if active != candidate or existing != candidate:
                raise ValueError('Active or on-disk Caddy routes differ from the reviewed legacy plan')
        if read_environment(environment) != original: raise ValueError('Business environment changed during inspection')
        return {'schema': 1, 'head': head, 'project': project, 'domain': domain,
                'environment_sha256': hashlib.sha256(original).hexdigest(),
                'caddy_service_sha256': hashlib.sha256(json.dumps(service, sort_keys=True).encode()).hexdigest(),
                'business_services_sha256': hashlib.sha256(json.dumps({name: value for name, value in config['services'].items() if name != 'caddy'}, sort_keys=True).encode()).hexdigest(),
                'caddy_id': current['id'], 'caddy_image_id': pinned,
                'caddy_started': current['started'], 'caddy_restarts': current['restarts'],
                'neighbors': snapshot({project, 'voicechat'}, excluding=ids, execute=execute)}
