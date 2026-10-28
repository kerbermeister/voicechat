"""Plan or explicitly execute centralized DuckDNS issuance; never activate TLS."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import uuid

import managed_state
import node_inventory
import tls_material
import topology

SERVERS = {'staging': 'https://acme-staging-v02.api.letsencrypt.org/directory',
           'production': 'https://acme-v02.api.letsencrypt.org/directory'}


def plan(public, inventory, config, edge_id, service):
    node_inventory.validate(inventory, public)
    topology.fields(config, ('schema', 'provider', 'environment', 'email', 'domains'))
    if (type(config['schema']) is not int or config['schema'] != 1 or
            config['provider'] != 'duckdns' or config['environment'] not in SERVERS):
        raise ValueError('Supported DuckDNS ACME configuration required')
    if not isinstance(config['email'], str) or not re.fullmatch(r'[a-zA-Z0-9._+%-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}', config['email']):
        raise ValueError('ACME contact email required')
    domains = config['domains']
    if (not isinstance(domains, list) or not 1 <= len(domains) <= 64 or
            any(not isinstance(item, str) or not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*\.duckdns\.org', item)
                or len(item.split('.')[0]) > 63 for item in domains) or len(set(domains)) != len(domains)):
        raise ValueError('Unique DuckDNS base domains required')
    names = tls_material.names(public, edge_id, service)
    if any(not any(name == domain or name.endswith('.' + domain) for domain in domains) for name in names):
        raise ValueError('Every TLS name must belong to an explicitly configured DuckDNS domain')
    node = node_inventory.edge_assignment(inventory, edge_id)
    image = topology.read_json(Path(__file__).with_name('acme-tools.json'))['lego']
    if not re.fullmatch(r'goacme/lego:v[0-9.]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('Pinned lego image required')
    return {'schema': 1, 'service_id': public['service_id'], 'edge_id': edge_id,
            'generation': node['generation'], 'ssh_host_key': node['ssh_host_key'],
            'service': service, 'names': names, 'image': image,
            'email': config['email'], 'server': SERVERS[config['environment']],
            'environment': config['environment'],
            'certificate_id': f"edge-{edge_id}-g{node['generation']}-{service}"}


def arguments(job):
    return ['run', '--path', '/state', '--server', job['server'], '--email', job['email'],
            '--accept-tos', '--dns', 'duckdns', '--cert.name', job['certificate_id'],
            '--key-type', 'EC256', '--http-timeout', '30', '--force-cert-domains',
            *(argument for name in job['names'] for argument in ('--domains', name))]


def create_command(job, state, token, container_name):
    if any(',' in str(value) or '\n' in str(value) for value in (state, token)):
        raise ValueError('Unsupported Docker bind path')
    return ['docker', 'create', '--name', container_name, '--read-only', '--cap-drop', 'ALL',
            '--security-opt', 'no-new-privileges:true', '--pids-limit', '128',
            '--user', f'{os.geteuid()}:{os.getegid()}', '--tmpfs', '/tmp:rw,nosuid,nodev,size=16m',
            '--workdir', '/tmp', '--mount', f'type=bind,source={state},target=/state',
            '--mount', f'type=bind,source={token},target=/run/secrets/duckdns,readonly',
            '--env', 'DUCKDNS_TOKEN_FILE=/run/secrets/duckdns',
            '--env', 'LEGO_DISABLE_CNAME_SUPPORT=true',
            '--env', 'DUCKDNS_PROPAGATION_TIMEOUT=180', '--env', 'DUCKDNS_SEQUENCE_INTERVAL=60',
            job['image'], *arguments(job)]


def execute(directory, public, inventory, config, edge_id, service, token_file, *,
            accept_tos=False, ca_file=None, run=subprocess.run):
    job = plan(public, inventory, config, edge_id, service)
    if accept_tos is not True: raise ValueError('Explicit acceptance of the CA terms is required')
    if ca_file is not None and config['environment'] != 'staging':
        raise ValueError('Production certificates must use the system trust store')
    token = tls_material.read_material(token_file, private=True).strip()
    if not re.fullmatch(rb'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', token):
        raise ValueError('DuckDNS account token format is invalid')
    directory = Path(directory).absolute()
    with managed_state.locked(directory) as root:
        pending = root / 'inflight.json'
        if pending.exists() or pending.is_symlink():
            raise ValueError('Interrupted ACME job requires container cleanup/reconciliation before any new job')
        binding = {key: job[key] for key in ('service_id', 'email', 'server')}
        receipt = root / 'account.json'
        if receipt.exists():
            if managed_state.read(receipt) != binding: raise ValueError('ACME account/environment changed')
        else:
            if {item.name for item in root.iterdir()} != {'apply.lock'}:
                raise ValueError('Refusing to adopt an unclaimed ACME directory')
            managed_state.persist(receipt, binding)
        # One lock spans all names and edges: DuckDNS TXT is shared by nested
        # names, so independent edge jobs must never run concurrently.
        state = root / 'lego'
        with managed_state.locked(state):
            requests = root / 'requests'
            with managed_state.locked(requests):
                request = requests / (job['certificate_id'] + '.json')
                identity = {key: value for key, value in job.items() if key != 'image'}
                if request.exists() and managed_state.read(request) != identity:
                    raise ValueError('TLS identity changed without a new host generation')
                managed_state.persist(request, identity)
            with tempfile.TemporaryDirectory(prefix='.credential-', dir=root) as temporary:
                token_path = Path(temporary) / 'token'
                tls_material.write_private(token_path, token)
                container = 'voicechat-acme-' + uuid.uuid4().hex
                command = create_command(job, state, token_path, container)
                managed_state.persist(pending, {'container': container, 'certificate_id': job['certificate_id']})
                # Keep the intent on uncertain create/cleanup outcomes. A killed
                # Docker CLI can leave the provider running; releasing the lock
                # alone must not allow another TXT writer to start.
                try:
                    created = run(command, capture_output=True, timeout=180)
                except (OSError, subprocess.TimeoutExpired):
                    raise ValueError('ACME container creation uncertain; reconcile inflight.json') from None
                if created.returncode:
                    raise ValueError('ACME container creation failed; reconcile inflight.json')
                try:
                    completed = run(['docker', 'start', '--attach', container], capture_output=True, timeout=1800)
                except (OSError, subprocess.TimeoutExpired):
                    raise ValueError('ACME execution failed or timed out') from None
                finally:
                    try:
                        cleaned = run(['docker', 'rm', '--force', container], capture_output=True, timeout=30)
                        if cleaned.returncode: raise ValueError('ACME container cleanup failed; reconcile inflight.json')
                    except (OSError, subprocess.TimeoutExpired):
                        raise ValueError('ACME container cleanup uncertain; reconcile inflight.json') from None
                    pending.unlink()
                    tls_material.sync_directory(root)
                if completed.returncode:
                    raise ValueError('ACME issuance failed; previous staged certificates were preserved')
            certificates = state / 'certificates'
            stem = job['certificate_id']
            return tls_material.stage(root / 'verified', public, edge_id, service,
                certificates / (stem + '.crt'), certificates / (stem + '.key'), ca_file=ca_file)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--topology', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--edge', required=True)
    parser.add_argument('--service', choices=('web', 'turn'), required=True)
    parser.add_argument('--execute', action='store_true', help='Calls the CA and changes DNS TXT records')
    parser.add_argument('--directory', type=Path)
    parser.add_argument('--token-file', type=Path)
    parser.add_argument('--accept-tos', action='store_true')
    parser.add_argument('--ca-file', type=Path, help='Explicit CA bundle for staging only')
    args = parser.parse_args()
    public, inventory, config = topology.load(args.topology), node_inventory.load(args.inventory), topology.read_json(args.config)
    if not args.execute:
        print(json.dumps(plan(public, inventory, config, args.edge, args.service), indent=2))
    else:
        if args.directory is None or args.token_file is None:
            parser.error('--execute requires --directory and --token-file')
        print(execute(args.directory, public, inventory, config, args.edge, args.service,
                      args.token_file, accept_tos=args.accept_tos, ca_file=args.ca_file))


if __name__ == '__main__': main()
