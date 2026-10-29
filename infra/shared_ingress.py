"""Stage, inspect and adopt the existing Avito Caddy before shared port cutover."""
from pathlib import PurePosixPath
from pathlib import Path
import hashlib
import json
import os
import re
import stat
import tempfile
import time
import uuid
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


def legacy_certificates_config(business_routes, public, edge_id):
    """Prepare cohost HTTP-01 certificates while retaining the old web upstream."""
    config = legacy_config(business_routes, public)
    edge = next((item for item in public['edges'] if item['id'] == edge_id), None)
    if edge is None or edge['origin'] != public['canonical_origin']:
        raise ValueError('Initial Caddy certificate preparation requires the canonical cohost origin')
    if edge['turn_host'] in business_routes: raise ValueError('Remove previous TURN routes from the business source')
    issuer = '''    tls {
        issuer acme {
            disable_tlsalpn_challenge
        }
    }
'''
    ending = '    reverse_proxy voicechat-web:80\n}\n'
    if not config.endswith(ending): raise ValueError('Legacy web route layout changed')
    # Port 80 stays with Caddy after the later SNI cutover; TLS-ALPN then belongs
    # to HAProxy's web/TURN backends and cannot validate Caddy's certificates.
    return config[:-len(ending)] + issuer + ending + '\n' + edge['turn_host'] + ' {\n' + issuer + '    respond 421\n}\n'


def configuration(business_routes, target):
    """Render the serving mode identically for staging and business updates."""
    if target['mode'] == 'shared':
        import edge_config
        profile = node_inventory.shared_tls(target['shared_tls'])
        return edge_config.shared_legacy_proxy(business_routes, target['public'],
            target['edge_id'], profile['ingress_ip'])
    if target['mode'] == 'legacy-certs':
        return legacy_certificates_config(business_routes, target['public'], target['edge_id'])
    if target['mode'] == 'legacy': return legacy_config(business_routes, target['public'])
    raise ValueError('Unknown shared ingress mode')


def stage(root, repo, edge_root, public, inventory, edge_id, business_routes, *, mode='legacy', system_root=Path('/')):
    """Stage an immutable plan/package without touching a live service or Git."""
    import managed_state
    root = Path(root).absolute()
    if root.resolve() != root: raise ValueError('Shared ingress root must not traverse symlinks')
    with managed_state.locked(root):
        return _stage_locked(root, repo, edge_root, public, inventory, edge_id, business_routes,
                             mode=mode, system_root=system_root)


def _stage_locked(root, repo, edge_root, public, inventory, edge_id, business_routes, *, mode='legacy', system_root=Path('/')):
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
    if mode not in ('legacy', 'legacy-certs', 'shared'): raise ValueError('Unknown shared ingress mode')
    profile = entry.get('shared_tls') if mode == 'shared' else None
    if mode == 'shared' and profile is None: raise ValueError('Shared TLS profile required before cutover')
    _, code, contents, _, operator = role_bootstrap.plan(edge_root, 'edge', edge_id)
    target = {'schema': 1, 'repo': repo, 'edge_root': str(edge_root), 'edge_id': edge_id,
              'mode': mode, 'public': public, 'node': inventory['core'], 'shared_tls': profile,
              'operator': operator}
    role_bootstrap.install_sources(Path(system_root).resolve(), code, contents)
    return _store_plan_locked(root, target, configuration(business_routes, target), system_root=system_root)


def _store_plan_locked(root, target, configuration, *, system_root):
    import managed_state
    import network_bootstrap
    import role_bootstrap
    import role_prepare
    import role_release
    role_bootstrap.verify_record(Path(system_root).resolve(), target['operator'])
    files = {'Caddyfile': configuration.encode(), 'compose.override.yaml':
             compose_override(str(root / 'runtime/caddy'), shared=target['shared_tls']).encode(),
             'compose.env-line': compose_environment(target['repo'], str(root / 'runtime/compose.override.yaml')).encode()}
    record = {'schema': 1, 'target': target,
              'files': {name: hashlib.sha256(content).hexdigest() for name, content in files.items()}}
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
    for name, content in files.items():
        if network_bootstrap.existing(plan / name) is None:
            network_bootstrap.create_file(plan / name, content)
    managed_state.persist(manifest, record)
    return plan


def read_plan(root, plan, *, system_root=Path('/'), current_sources=True):
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
    if type(target['schema']) is not int or target['schema'] != 1 or target['mode'] not in ('legacy', 'legacy-certs', 'shared'):
        raise ValueError('Unsupported shared ingress target')
    public = topology.validate(target['public'])
    node_inventory.validate({'schema': 1, 'service_id': public['service_id'], 'ssh_user': 'root',
        'ssh_port': 22, 'core': target['node'], 'edges': [{'id': target['edge_id'], 'host': 'core'}]})
    if target['edge_id'] not in {edge['id'] for edge in public['edges']}:
        raise ValueError('Shared edge is absent from its topology')
    absolute_path(target['repo']); absolute_path(target['edge_root'])
    if target['mode'] == 'shared': node_inventory.shared_tls(target['shared_tls'])
    elif target['shared_tls'] is not None: raise ValueError('Legacy plan cannot claim a shared bridge')
    if current_sources:
        expected = role_bootstrap.plan(Path(target['edge_root']), 'edge', target['edge_id'])[4]
        if target['operator'] != expected: raise ValueError('Restage the plan with the reviewed operator sources')
    role_bootstrap.verify_record(Path(system_root).resolve(), target['operator'])
    operator = target['operator']
    if operator['root'] != target['edge_root'] or operator['role'] != 'edge' or operator['edge_id'] != target['edge_id']:
        raise ValueError('Shared plan operator belongs to another role')
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
        return _inspect_legacy_locked(root, plan, execute=execute, system_root=system_root)


def _inspect_legacy_locked(root, plan, *, execute, system_root):
    import network_bootstrap
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
            'source_sha256': hashlib.sha256(host).hexdigest(),
            'compose_sha256': hashlib.sha256(read_environment(base)).hexdigest(),
            'environment_sha256': hashlib.sha256(original).hexdigest(),
            'caddy_service_sha256': hashlib.sha256(json.dumps(service, sort_keys=True).encode()).hexdigest(),
            'business_services_sha256': hashlib.sha256(json.dumps({name: value for name, value in config['services'].items() if name != 'caddy'}, sort_keys=True).encode()).hexdigest(),
            'caddy_id': current['id'], 'caddy_image_id': pinned,
            'caddy_started': current['started'], 'caddy_restarts': current['restarts'],
            'neighbors': snapshot({project, 'voicechat'}, excluding=ids, execute=execute)}


def _write(path, content, *, mode=0o600):
    """Atomic server-local replacement, including directory durability."""
    descriptor, temporary = tempfile.mkstemp(prefix='.shared-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            os.fchmod(output.fileno(), mode)
            output.write(content); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, path)
        _sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def _sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)


def _compose(target, environment, *overrides):
    repo = Path(target['repo'])
    result = ['docker', 'compose', '--project-directory', str(repo / 'deploy'), '--env-file', str(environment),
              '-f', str(repo / 'deploy/docker-compose.yml')]
    for path in overrides: result += ['-f', str(path)]
    return result


def _source_unchanged(target, baseline, *, execute):
    repo = Path(target['repo'])
    if execute(['git', '--no-pager', '-C', str(repo), 'rev-parse', 'HEAD']).decode().strip() != baseline['head']:
        raise ValueError('Business revision changed during ingress adoption')
    for name, field in (('Caddyfile', 'source_sha256'), ('docker-compose.yml', 'compose_sha256')):
        if hashlib.sha256(read_environment(repo / 'deploy' / name)).hexdigest() != baseline[field]:
            raise ValueError('Business source changed during ingress adoption')


def _candidate_model(root, target, original, candidate, plan, *, execute):
    """Compose itself must prove that only the reviewed Caddy mount/image change."""
    repo = Path(target['repo'])
    with tempfile.TemporaryDirectory(prefix='voicechat-shared-model-') as temporary:
        temporary = Path(temporary)
        before, after = temporary / 'before.env', temporary / 'after.env'
        _write(before, original); _write(after, candidate)
        base = repo / 'deploy/docker-compose.yml'
        old = compose_config(repo, before, base, execute=execute)
        new = compose_config(repo, after, base, plan / 'compose.override.yaml', execute=execute)
    old_service, new_service = old['services']['caddy'], new['services']['caddy']
    if ({key: value for key, value in old.items() if key != 'services'} !=
            {key: value for key, value in new.items() if key != 'services'} or
            {key: value for key, value in old['services'].items() if key != 'caddy'} !=
            {key: value for key, value in new['services'].items() if key != 'caddy'}):
        raise ValueError('Shared ingress must preserve all neighboring Compose definitions')
    if {key: value for key, value in old_service.items() if key not in ('image', 'volumes')} != {
            key: value for key, value in new_service.items() if key not in ('image', 'volumes')}:
        raise ValueError('Initial adoption may only change the Caddy image pin and configuration mount')
    volumes = {item['target']: item for item in new_service['volumes']}
    expected = {item['target']: item for item in old_service['volumes'] if item['target'] != '/etc/caddy/Caddyfile'}
    expected['/etc/caddy'] = {'type': 'bind', 'source': str(root / 'runtime/caddy'), 'target': '/etc/caddy',
                            'read_only': True, 'bind': {'create_host_path': False}}
    if new_service['image'] != CADDY_IMAGE or volumes != expected:
        raise ValueError('Candidate Caddy mounts differ from the reviewed directory migration')


def _https_health(target, baseline, *, execute):
    for hostname, path in ((baseline['domain'], '/'),
                           (urlsplit(target['public']['canonical_origin']).hostname, '/_matrix/client/versions')):
        execute(['curl', '--fail', '--silent', '--show-error', '--max-time', '10', '--output', '/dev/null',
                 '--noproxy', '*', '--resolve', hostname + ':443:127.0.0.1', 'https://' + hostname + path])


def _verify_live(root, target, files, record, *, managed, execute, health):
    """Confirm process/config/volume identity and both HTTPS routes after recreation."""
    baseline = record['baseline']
    repo = Path(target['repo'])
    _source_unchanged(target, baseline, execute=execute)
    environment = repo / 'deploy/.env'
    expected_env = record['managed_environment_sha256'] if managed else baseline['environment_sha256']
    if hashlib.sha256(read_environment(environment)).hexdigest() != expected_env:
        raise ValueError('Environment changed during ingress adoption')
    ids = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter',
        'label=com.docker.compose.project=' + baseline['project'], '--filter', 'label=com.docker.compose.service=caddy']).decode().split()
    if len(ids) != 1 or not re.fullmatch(r'[a-f0-9]{64}', ids[0]): raise ValueError('One adopted Caddy required')
    template = ('{"running":{{json .State.Running}},"image":{{json .Image}},"mounts":{{json .Mounts}},'
                '"ports":{{json .HostConfig.PortBindings}},"restart":{{json .HostConfig.RestartPolicy}},'
                '"networks":{{json .NetworkSettings.Networks}}}')
    current = json.loads(execute(['docker', 'inspect', '--format', template, ids[0]]))
    if not current['running'] or current['image'] != baseline['caddy_image_id']:
        raise ValueError('Adopted Caddy binary or running state changed')
    mounts = {item['Destination']: item for item in current['mounts']}
    config_target = '/etc/caddy' if managed else '/etc/caddy/Caddyfile'
    config_source = root / 'runtime/caddy' if managed else repo / 'deploy/Caddyfile'
    if set(mounts) != {config_target, '/data', '/config'}:
        raise ValueError('Adopted Caddy mount set changed')
    if mounts[config_target]['Type'] != 'bind' or mounts[config_target]['RW'] or mounts[config_target]['Source'] != str(config_source):
        raise ValueError('Adopted Caddy configuration mount changed')
    for destination, name in (('/data', 'caddy_data'), ('/config', 'caddy_config')):
        if (mounts[destination]['Type'] != 'volume' or not mounts[destination]['RW'] or
                mounts[destination]['Name'] != record['volumes'][name]):
            raise ValueError('Caddy data volume identity changed')
    if (current['ports'] != record['ports'] or current['restart'] != record['restart'] or
            set(current['networks']) != set(record['networks'])):
        raise ValueError('Caddy availability settings changed')
    if snapshot({baseline['project'], 'voicechat'}, excluding=ids, execute=execute) != baseline['neighbors']:
        raise ValueError('Neighboring services changed during Caddy-only adoption')
    with tempfile.TemporaryDirectory(prefix='voicechat-shared-verify-') as temporary:
        path = Path(temporary) / 'Caddyfile'; _write(path, files['Caddyfile'])
        expected = json.loads(execute(['docker', 'run', '--rm', '--network', 'none', '--env', 'DOMAIN=' + baseline['domain'],
            '--volume', str(path) + ':/etc/caddy/Caddyfile:ro', CADDY_IMAGE,
            'caddy', 'adapt', '--config', '/etc/caddy/Caddyfile', '--adapter', 'caddyfile']))
    end = time.monotonic() + 60
    while True:
        try:
            active = json.loads(execute(['docker', 'exec', ids[0], 'wget', '-q', '-O', '-', '-T', '5', '-Y', 'off',
                                        'http://127.0.0.1:2019/config/']))
            if active != expected: raise ValueError('Recreated Caddy does not serve the reviewed routes')
            health(target, baseline, execute=execute)
            break
        except RuntimeError:
            if time.monotonic() >= end: raise
            time.sleep(1)
    _source_unchanged(target, baseline, execute=execute)
    if (hashlib.sha256(read_environment(environment)).hexdigest() != expected_env or
            snapshot({baseline['project'], 'voicechat'}, excluding=ids, execute=execute) != baseline['neighbors']):
        raise ValueError('Environment or neighboring services changed during HTTPS verification')


def _attempt(root, record, *, system_root, allow_shared=False):
    """Validate an owned pending/committed journal before any recovery commands."""
    import topology
    topology.fields(record, ('schema', 'attempt', 'plan', 'baseline', 'managed_environment_sha256',
                             'environment_mode', 'volumes', 'ports', 'restart', 'networks'))
    if type(record['schema']) is not int or record['schema'] != 1 or not re.fullmatch(r'[a-f0-9]{32}', record['attempt']):
        raise ValueError('Invalid shared ingress adoption journal')
    if not re.fullmatch(r'[a-f0-9]{64}', record['plan']): raise ValueError('Invalid recorded plan')
    if record['environment_mode'] not in (0o600, 0o640, 0o644): raise ValueError('Invalid environment recovery permissions')
    plan = root / 'plans' / record['plan']
    target, files = read_plan(root, plan, system_root=system_root, current_sources=False)
    if target['mode'] == 'shared' and not allow_shared:
        raise ValueError('Legacy journal cannot activate a shared cutover')
    host = Path(system_root) / 'etc/ssh/ssh_host_ed25519_key.pub'
    if node_inventory.host_key(' '.join(read_environment(host).decode().split()[:2])) != target['node']['ssh_host_key']:
        raise ValueError('Shared recovery journal belongs to another SSH host')
    directory = root / 'attempts' / record['attempt']
    if directory.resolve() != directory: raise ValueError('Recovery directory cannot traverse symlinks')
    original = read_environment(directory / 'original.env')
    expected = original + (b'\n' if original and not original.endswith(b'\n') else b'') + files['compose.env-line']
    if (hashlib.sha256(original).hexdigest() != record['baseline']['environment_sha256'] or
            hashlib.sha256(expected).hexdigest() != record['managed_environment_sha256']):
        raise ValueError('Environment recovery snapshot changed')
    return target, files, directory, original, expected


def _recover_locked(root, record, *, execute, health, system_root):
    import managed_state
    target, files, directory, original, expected = _attempt(root, record, system_root=system_root)
    environment = Path(target['repo']) / 'deploy/.env'
    if read_environment(environment) not in (original, expected):
        raise ValueError('Refusing to overwrite an externally changed business environment during recovery')
    _source_unchanged(target, record['baseline'], execute=execute)
    # Revert the directory ownership line, then explicitly pin the original
    # binary. A mutable caddy:2.8 tag must not turn rollback into an upgrade.
    _write(environment, original, mode=record['environment_mode'])
    pin = directory / 'rollback-image.json'
    wanted = json.dumps({'services': {'caddy': {'image': CADDY_IMAGE}}}).encode()
    if pin.exists() and read_environment(pin) != wanted: raise ValueError('Recovery image override changed')
    _write(pin, wanted)
    execute([*_compose(target, environment, pin), 'up', '-d', '--no-deps', '--no-build', '--pull', 'never', 'caddy'],
            env={**os.environ, 'PWD': str(Path(target['repo']) / 'deploy')})
    _verify_live(root, target, files, record, managed=False, execute=execute, health=health)
    managed_state.persist(directory / 'recovered.json', {'schema': 1, 'plan': record['plan']})
    (root / 'pending.json').unlink(); _sync_directory(root)


def adopt_legacy(root, plan, *, execute=None, health=_https_health, system_root=Path('/')):
    """Move only Caddy to an owned directory mount, with recoverable .env intent.

    No Git checkout, application image pull or database operation is performed.
    An interrupted attempt is rolled back before accepting another adoption.
    """
    import managed_state
    import network_bootstrap
    import role_prepare
    if execute is None:
        from role_deploy import run
        execute = run
    root, plan = Path(root).absolute(), Path(plan).absolute()
    if root.resolve() != root or not root.is_dir(): raise ValueError('Prepared shared root required')
    with managed_state.locked(root):
        if (root / 'update.json').exists() or (root / 'update.json').is_symlink():
            raise ValueError('Finish the pending business deployment before ingress adoption')
        if (root / 'configuration.json').exists() or (root / 'configuration.json').is_symlink():
            raise ValueError('Finish the pending ingress configuration change before adoption')
        current, pending = root / 'current.json', root / 'pending.json'
        if current.exists() or current.is_symlink():
            record = managed_state.read(current)
            target, files, _, _, _ = _attempt(root, record, system_root=system_root)
            if plan != root / 'plans' / record['plan']: raise ValueError('Shared ingress already adopted; explicit upgrade required')
            for name, content in (('caddy/Caddyfile', files['Caddyfile']), ('compose.override.yaml', files['compose.override.yaml'])):
                if read_environment(root / 'runtime' / name) != content: raise ValueError('Managed shared runtime changed')
            _verify_live(root, target, files, record, managed=True, execute=execute, health=health)
            if pending.exists() or pending.is_symlink():
                if managed_state.read(pending) != record: raise ValueError('Conflicting committed/pending ingress journal')
                pending.unlink(); _sync_directory(root)
            return record
        if pending.exists() or pending.is_symlink():
            _recover_locked(root, managed_state.read(pending), execute=execute, health=health, system_root=system_root)
            raise ValueError('Interrupted legacy adoption recovered; retry the reviewed plan')
        target, files = read_plan(root, plan, system_root=system_root)
        baseline = _inspect_legacy_locked(root, plan, execute=execute, system_root=system_root)
        health(target, baseline, execute=execute)
        environment = Path(target['repo']) / 'deploy/.env'
        original = read_environment(environment)
        expected = original + (b'\n' if original and not original.endswith(b'\n') else b'') + files['compose.env-line']
        if hashlib.sha256(original).hexdigest() != baseline['environment_sha256']:
            raise ValueError('Business environment changed after preflight')
        _candidate_model(root, target, original, expected, plan, execute=execute)
        # Capture only non-secret inspect fields for exact rollback assertions.
        template = '{"mounts":{{json .Mounts}},"ports":{{json .HostConfig.PortBindings}},"restart":{{json .HostConfig.RestartPolicy}},"networks":{{json .NetworkSettings.Networks}}}'
        before = json.loads(execute(['docker', 'inspect', '--format', template, baseline['caddy_id']]))
        role_prepare.directory(root / 'attempts')
        attempt = uuid.uuid4().hex; directory = root / 'attempts' / attempt
        role_prepare.directory(directory)
        _write(directory / 'original.env', original)
        record = {'schema': 1, 'attempt': attempt, 'plan': plan.name, 'baseline': baseline,
                  'managed_environment_sha256': hashlib.sha256(expected).hexdigest(),
                  'environment_mode': stat.S_IMODE(environment.stat().st_mode),
                  'volumes': {name: next(item['Name'] for item in before['mounts'] if item['Destination'] == destination)
                              for name, destination in (('caddy_data', '/data'), ('caddy_config', '/config'))},
                  **{key: before[key] for key in ('ports', 'restart', 'networks')}}
        # Do not persist dynamic endpoint IDs or addresses; network names suffice.
        record['networks'] = sorted(record['networks'])
        if record['environment_mode'] not in (0o600, 0o640, 0o644): raise ValueError('Unsupported environment permissions')
        managed_state.persist(pending, record)
        try:
            role_prepare.directory(root / 'runtime'); role_prepare.directory(root / 'runtime/caddy')
            for name, content in (('caddy/Caddyfile', files['Caddyfile']), ('compose.override.yaml', files['compose.override.yaml'])):
                path = root / 'runtime' / name
                existing = network_bootstrap.existing(path)
                if existing not in (None, content): raise ValueError('Unknown shared runtime must not be overwritten')
                if existing is None: _write(path, content)
            if read_environment(environment) != original: raise ValueError('Environment changed before adoption')
            _write(environment, expected)
            execute([*_compose(target, environment, root / 'runtime/compose.override.yaml'),
                     'up', '-d', '--no-deps', '--no-build', '--pull', 'never', 'caddy'],
                    env={**os.environ, 'PWD': str(Path(target['repo']) / 'deploy')})
            _verify_live(root, target, files, record, managed=True, execute=execute, health=health)
            managed_state.persist(current, record)
            pending.unlink(); _sync_directory(root)
        except Exception:
            if not current.exists():
                _recover_locked(root, record, execute=execute, health=health, system_root=system_root)
            raise
        return record
