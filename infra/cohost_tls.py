"""Capture verified cohost Caddy certificates locally, without serving changes."""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import time

import managed_state
import node_inventory
from role_deploy import run
import shared_ingress as ingress
import shared_update
import tls_activation
import tls_material
import topology

# Pinned Caddy 2.8 filesystem storage for our explicit default ACME issuer.
# Do not guess another issuer or select an old cached key after CA rotation.
ISSUER = 'acme-v02.api.letsencrypt.org-directory'


def _owned_directory(path):
    info = path.lstat()
    if (path.resolve() != path or not stat.S_ISDIR(info.st_mode) or
            info.st_uid != os.geteuid() or info.st_mode & 0o022):
        raise ValueError('Caddy certificate source must be an owned canonical directory')


def _source(root, *, execute, system_root):
    for name in ('pending.json', 'update.json', 'configuration.json'):
        if (root / name).exists() or (root / name).is_symlink():
            raise ValueError('Finish ingress maintenance before capturing certificates')
    record = managed_state.read(root / 'current.json')
    if not isinstance(record.get('plan'), str) or not re.fullmatch(r'[a-f0-9]{64}', record['plan']):
        raise ValueError('Invalid current ingress plan')
    target, files = ingress.read_plan(root, root / 'plans' / record['plan'], system_root=system_root, current_sources=False)
    if target['mode'] not in ('legacy-certs', 'shared'):
        raise ValueError('Prepare cohost certificates before capturing them')
    edge = next(item for item in target['public']['edges'] if item['id'] == target['edge_id'])
    if edge['origin'] != target['public']['canonical_origin']:
        raise ValueError('Caddy capture requires the canonical cohost origin; use the SAN issuer for other origins')
    owner = shared_update._manager(root, execute=execute, system_root=Path(system_root).resolve())
    if owner['operator'] != target['operator']: raise ValueError('Ingress manager owner differs from the serving plan')
    host = Path(system_root) / 'etc/ssh/ssh_host_ed25519_key.pub'
    if node_inventory.host_key(' '.join(ingress.read_environment(host).decode().split()[:2])) != target['node']['ssh_host_key']:
        raise ValueError('Caddy certificate capture belongs to another SSH host')
    for name, content in (('caddy/Caddyfile', files['Caddyfile']), ('compose.override.yaml', files['compose.override.yaml'])):
        if ingress.read_environment(root / 'runtime' / name) != content: raise ValueError('Serving Caddy configuration changed')
    project = record['baseline']['project']
    if not isinstance(project, str) or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,62}', project):
        raise ValueError('Invalid Caddy project identity')
    ids = execute(['docker', 'ps', '-aq', '--no-trunc', '--filter', 'label=com.docker.compose.project=' + project,
                   '--filter', 'label=com.docker.compose.service=caddy']).decode().split()
    if len(ids) != 1 or not re.fullmatch(r'[a-f0-9]{64}', ids[0]): raise ValueError('One managed Caddy required')
    template = ('{"id":{{json .Id}},"image_id":{{json .Image}},"running":{{json .State.Running}},'
                '"labels":{{json .Config.Labels}},"mounts":{{json .Mounts}},"ports":{{json .HostConfig.PortBindings}}}')
    current = json.loads(execute(['docker', 'inspect', '--format', template, ids[0]]))
    if (current['id'] != ids[0] or not current['running'] or current['image_id'] != record['baseline']['caddy_image_id'] or
            current['labels'].get('com.docker.compose.project') != project or
            current['labels'].get('com.docker.compose.service') != 'caddy' or current['ports'] != record['ports']):
        raise ValueError('Caddy process or port ownership changed')
    mounts = {item['Destination']: item for item in current['mounts']}
    if set(mounts) != {'/data', '/config', '/etc/caddy'}: raise ValueError('Unexpected Caddy source mounts')
    if (mounts['/etc/caddy']['Type'] != 'bind' or mounts['/etc/caddy']['RW'] or
            mounts['/etc/caddy']['Source'] != str(root / 'runtime/caddy')):
        raise ValueError('Caddy configuration mount changed')
    for destination, name in (('/data', 'caddy_data'), ('/config', 'caddy_config')):
        if (mounts[destination]['Type'] != 'volume' or not mounts[destination]['RW'] or
                mounts[destination]['Name'] != record['volumes'][name]):
            raise ValueError('Caddy certificate data volume changed')
    volume = record['volumes']['caddy_data']
    if not isinstance(volume, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', volume):
        raise ValueError('Invalid certificate volume identity')
    template = '{"name":{{json .Name}},"driver":{{json .Driver}},"mountpoint":{{json .Mountpoint}},"options_empty":{{eq (len .Options) 0}}}'
    storage = json.loads(execute(['docker', 'volume', 'inspect', '--format', template, volume]))
    if storage['name'] != volume or storage['driver'] != 'local' or not storage['options_empty']:
        raise ValueError('Local owned Caddy certificate storage required')
    directory = Path(ingress.absolute_path(storage['mountpoint']))
    if mounts['/data']['Source'] != str(directory): raise ValueError('Certificate volume mountpoint changed')
    _owned_directory(directory)
    for name in ('caddy', 'certificates', ISSUER):
        directory /= name; _owned_directory(directory)
    return target, directory, volume


def capture(root, *, execute=run, system_root=Path('/'), ca_file=None):
    """Snapshot and validate both private pairs on A; never export or activate.

    Caddy may replace chain/key separately during renewal. An inconsistent read
    is retried, never selected. Only a complete validated set updates the receipt.
    """
    root = Path(root).absolute()
    if root.resolve() != root or not root.is_dir(): raise ValueError('Prepared canonical ingress root required')
    with managed_state.locked(root):
        target, source, volume = _source(root, execute=execute, system_root=system_root)
        public, edge = target['public'], target['edge_id']
        identity = {'service_id': public['service_id'], 'canonical_origin': public['canonical_origin'],
                    'matrix_server_name': public['matrix_server_name'], 'edge_id': edge, 'volume': volume}
        receipt = root / 'certificates.json'
        if receipt.exists() or receipt.is_symlink():
            previous = managed_state.read(receipt)
            topology.fields(previous, ('schema', 'identity', 'generations'))
            if type(previous['schema']) is not int or previous['schema'] != 1 or previous['identity'] != identity:
                raise ValueError('Caddy certificate cache belongs to another identity')
            topology.fields(previous['generations'], ('web', 'turn'))
            if any(not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value)
                   for value in previous['generations'].values()):
                raise ValueError('Invalid Caddy certificate cache generation')
        generations = {}
        for service in ('web', 'turn'):
            names = tls_material.names(public, edge, service)
            if len(names) != 1: raise ValueError('Caddy capture requires one exact hostname per service')
            directory = source / names[0]; _owned_directory(directory)
            chain, key = directory / (names[0] + '.crt'), directory / (names[0] + '.key')
            for path in (chain, key):
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
                    raise ValueError('Caddy certificate source file is not owned or regular')
            if key.stat().st_mode & 0o077: raise ValueError('Caddy private key must remain owner-only')
            for attempt in range(3):
                try:
                    staged = tls_material.stage(root / 'certificates', public, edge, service, chain, key, ca_file=ca_file)
                    if target['mode'] == 'legacy-certs':
                        # Here Caddy still owns :443, so also require its exact
                        # live leaf. After shared cutover :443 belongs to edge.
                        tls_activation.verify_live('127.0.0.1', 443, names,
                            tls_material.read_material(staged / (service + '.crt'), private=True), ca_file=ca_file)
                    break
                except (OSError, ValueError):
                    if attempt == 2: raise RuntimeError('Caddy TLS source is not a complete trusted current pair') from None
                    time.sleep(.2)
            generations[service] = staged.name
        result = {'schema': 1, 'identity': identity, 'generations': generations}
        managed_state.persist(receipt, result)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0: raise SystemExit('Capture requires the cohost deployment owner/root')
    result = capture(args.root)
    print(json.dumps({'staged_only': True, 'generations': result['generations']}))


if __name__ == '__main__': main()
