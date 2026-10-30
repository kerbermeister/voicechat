"""Install or replace one entry from an operator Mac/CI using pinned SSH.

The only signing private key is operator-local. Resume uses the original private
state directory and exact clean source checkout; never create a second attempt
when the first operation is uncertain.
"""
import argparse
from copy import deepcopy
import ipaddress
import json
import os
import re
import secrets
from pathlib import Path
import shlex
import subprocess
import time

import entry_core
import entry_image
import entry_lifecycle
import entry_package
import entry_settings
import entry_peer
import host_connection
import host_prepare
import managed_ssh
import managed_state
import managed_release
import node_inventory
import role_release
import route_catalog
import ssh_deploy
import topology
from tunnel_config import physical_nodes


def target(baseline, entry):
    topology.fields(entry, ('id', 'public_ip', 'ssh_host_key', *(name for name in ('origin', 'turn_host') if name in entry)))
    public, inventory = deepcopy(baseline['public']), deepcopy(baseline['inventory'])
    old = next((item for item in inventory['edges'] if item['id'] == entry['id']), None)
    if old is not None:
        if 'host' in old or any(name in entry for name in ('origin', 'turn_host')):
            raise ValueError('Replacement retains names and cannot move a cohost entry')
        old.update(generation=old['generation'] + 1, public_ip=entry['public_ip'], ssh_host_key=entry['ssh_host_key'])
    else:
        if not all(name in entry for name in ('origin', 'turn_host')):
            raise ValueError('A new entry needs its permanent HTTPS and TURN names')
        occupied = {item['tunnel_ip'] for item in physical_nodes(inventory).values()}
        pool = ipaddress.ip_network(inventory['core']['tunnel_ip'] + '/24', strict=False)
        address = next((str(item) for item in pool.hosts() if str(item) not in occupied), None)
        if address is None: raise ValueError('No unused private entry address')
        inventory['edges'].append({'id': entry['id'], 'generation': 1, 'public_ip': entry['public_ip'],
                                  'tunnel_ip': address, 'ssh_host_key': entry['ssh_host_key']})
        public['edges'].append({name: entry[name] for name in ('id', 'origin', 'turn_host')})
        if entry['origin'] not in public['web_origins']: public['web_origins'].append(entry['origin'])
    entry_lifecycle.change(baseline['public'], baseline['inventory'], public, inventory)
    return public, inventory


def physical(inventory, role):
    if role == 'core': return 'core'
    edge = next(item for item in inventory['edges'] if item['id'] == role.removeprefix('edge-'))
    return 'core' if edge.get('host') == 'core' else role


def manifest(baseline, role):
    return baseline['core'] if role == 'core' else baseline['edges'][role.removeprefix('edge-')]


class Driver:
    def __init__(self, root, record, identities, state_dir):
        self.root, self.record, self.identities, self.state_dir = root, record, identities, state_dir
        self.settings = entry_settings.load(state_dir / 'settings') if isinstance(record['settings'], str) else record['settings']
        if isinstance(record['settings'], str) and role_release.json_digest(self.settings) != record['settings']:
            raise ValueError('Frozen operator settings changed')
        self.archive = state_dir / 'source.tar.gz'
        self.source, self.commit = record['delivery']['source'], record['delivery']['commit']
        self.before = managed_release.load_baseline(state_dir, record['baseline']) if isinstance(record['baseline'], str) else record['baseline']
        self.public, self.inventory = record['public'], record['inventory']
        self.plan = entry_lifecycle.plan(self.before, self.public, self.inventory, self.commit,
                                         record['delivery']['manifest']['web'])
        self.attempt = record.get('attempt')
        self.delivered = {'core'}

    def invoke(self, node, entry, value):
        parser = entry_core.request if entry == 'entry_core' else entry_peer.request
        raw = json.dumps(value, separators=(',', ':')).encode(); parser(raw)
        command = ['python3', '-B', self.root + '/bundles/' + self.source + '/infra/' + entry + '.py',
                   '--root', self.root, '--source-sha', self.source]
        with host_connection.connection(self.inventory, node, self.identities[node]) as ssh:
            if node not in self.delivered:
                delivered = ssh_deploy.receive(ssh, self.root, self.commit, self.archive)
                if delivered['archive_sha256'] != self.source:
                    raise ValueError('Entry source delivery differs from the frozen coordinator')
                self.delivered.add(node)
            for retry in range(3):
                response = subprocess.run([*ssh, shlex.join(command)], input=raw, capture_output=True, timeout=3600)
                if response.returncode == 0:
                    if len(response.stdout) > entry_core.MAX_INPUT:
                        raise ValueError('Oversized entry SSH response')
                    return json.loads(response.stdout, object_pairs_hook=topology.unique_object)
                if response.returncode not in (75, 255) or retry == 2:
                    # Preserve diagnostic text privately, never the JSON request
                    # (which may carry TLS material or an ephemeral read token).
                    failure = self.state_dir / 'last-error.log'
                    failure.write_bytes(response.stderr[-65536:]); failure.chmod(0o600)
                    raise RuntimeError('Entry operation failed; preserve state and inspect its private journal')
                time.sleep(retry + 1)
        raise RuntimeError('Entry SSH retry limit exceeded')

    def core(self, action, **fields):
        return self.invoke('core', 'entry_core', {'schema': 1, 'action': action, **fields})

    def peer(self, action, role, **extra):
        node = physical(self.inventory, role)
        is_new = node == self.plan['node']
        before = None if is_new else manifest(self.before, role)
        return self.invoke(node, 'entry_peer', {'schema': 1, 'action': action, 'attempt': self.attempt,
            'node': node, 'before_public': self.before['public'], 'previous_inventory': self.before['inventory'],
            'public': self.public, 'inventory': self.inventory, 'before': before,
            'target': manifest(self.plan['target'], role), 'core': self.plan['target']['core'],
            'subnet': self.before['subnet'], 'extra': extra})

    def prepared(self, **options):
        return host_prepare.prepare(self.inventory, self.plan['node'], self.identities[self.plan['node']],
            self.commit, self.archive, subnet=self.before['subnet'], **options)

    def configure(self, node, secret):
        result = {}
        for role in entry_lifecycle.role_ids(self.inventory, node):
            self.peer('configure', role, turn_secret=secret)
            result[role] = self.peer('observe', role)
        return {'roles': result}

    def execute(self, step, status):
        action, node = step['action'], step['node']
        new = self.plan['node']
        if action == 'prepare': return self.prepared()
        if action == 'identity': return self.prepared(initialize_key=True)['tunnel_identity']
        if action == 'register':
            identity = self.prepared(initialize_key=True)['tunnel_identity']
            return self.core('register', attempt=self.attempt, identity=identity)
        if action == 'network' and node == new:
            return self.prepared(public_keys=status['registration']['public_keys'])['network']
        if action == 'tls':
            material = self.core('certificates', attempt=self.attempt)
            secret = self.core('secret', attempt=self.attempt)['secret']
            return self.peer('material', new, **material, turn_secret=secret,
                catalog=self.settings['catalog'], catalog_key=status['catalog_key'])
        if action == 'stage':
            result = self.peer('stage', new)
            image = self.peer('image', new, token=None)
            if image.get('needs_reader') is True:
                reader = self.core('image-token', attempt=self.attempt)
                expected = entry_image.repository(self.plan['target']['edges'][self.plan['edge_id']]['images']['web'])
                if reader['repository'] != expected or reader['actions'] != ['pull']:
                    raise ValueError('Only the selected image repository-read bearer is permitted')
                image = self.peer('image', new, token=reader['token'])
            if image.get('image_ready') is not True: raise ValueError('Entry web image is not ready')
            return {'prepared': result, 'image': image}
        if action == 'claim':
            return {'roles': {role: self.peer('claim', role) for role in entry_lifecycle.role_ids(self.before['inventory'], node)}}
        if action == 'network':
            return self.invoke(node, 'entry_peer', {'schema': 1, 'action': 'network', 'attempt': self.attempt,
                'node': node, 'before_public': self.before['public'], 'previous_inventory': self.before['inventory'],
                'public': self.public, 'inventory': self.inventory, 'before': None, 'target': None, 'core': None,
                'subnet': self.before['subnet'], 'extra': {'public_keys': status['public_keys'],
                                                        'identity': status['registration']['identity']}})
        if action == 'rotate-turn':
            return self.configure(node, self.core('secret', attempt=self.attempt)['secret'])
        if action == 'configure':
            self.peer('configure', node, turn_secret=None)
            return self.peer('observe', node)
        if action in ('start', 'verify'):
            return self.peer('start' if action == 'start' else 'observe', new)
        if action == 'verify-turn':
            previous = self.core('turn-previous-credential', attempt=self.attempt) if self.plan['rotate_turn_secret'] else None
            return self.peer('turn', node, previous=previous)
        if action == 'dns': return self.core('dns', attempt=self.attempt)
        if action == 'verify-dns':
            # A verifies resolver convergence; candidate readiness is independently
            # rechecked by numeric IP with the permanent trusted SNI name.
            result = self.core('dns-observe', attempt=self.attempt)
            self.peer('observe', new)
            return result
        if action == 'catalog':
            result = {}
            for edge in self.public['edges']:
                role = 'edge-' + edge['id']
                proof = self.peer('catalog', role, catalog=self.settings['catalog'], catalog_key=status['catalog_key'])
                result[edge['id']] = {'revision': proof['catalog_revision']}
            return {'entries': result}
        if action == 'commit': return self.core('commit', attempt=self.attempt)
        if action == 'release':
            secret = self.core('secret', attempt=self.attempt)['secret'] if self.plan['rotate_turn_secret'] else None
            return {'roles': {role: self.peer('release', role, turn_secret=secret)
                             for role in entry_lifecycle.role_ids(self.inventory, node)}}
        if action == 'finish':
            self.peer('observe', new)
            return self.core('finish', attempt=self.attempt)
        raise ValueError('Unknown lifecycle step')

    def cancel(self):
        if self.attempt is None:
            snapshot = self.core('snapshot')
            pending = snapshot['pending']
            if pending is not None:
                target_ref = managed_release.store_baseline(self.state_dir, self.plan['target'])
                same = (pending['request']['source'] == self.source and pending['request']['target'] == target_ref and
                        pending['request']['settings'] == role_release.json_digest(self.settings))
                if pending['position'] == len(pending['steps']):
                    if same: raise ValueError('This entry operation already completed; inspect it with --execute')
                elif not same:
                    raise ValueError('A different entry operation is active; preserve its state')
                else:
                    self.attempt = pending['attempt']; self.record['attempt'] = self.attempt
                    managed_state.persist(self.state_dir / 'operation.json', self.record)
            if self.attempt is None:
                return {'schema': 1, 'attempt': None, 'phase': 'cancelled', 'local_only': True,
                        'live_hosts_unchanged': True}
        return self.core('cancel', attempt=self.attempt)

    def run(self):
        if self.attempt is None:
            started = self.core('begin', baseline=role_release.json_digest(self.before),
                public=self.public, inventory=self.inventory, settings=self.settings)
            self.attempt = started['attempt']; self.record['attempt'] = self.attempt
            managed_state.persist(self.state_dir / 'operation.json', self.record)
        for _ in range(256):
            status = self.core('status', attempt=self.attempt)
            journal = status['journal']; position = journal['position']
            if position == len(journal['steps']):
                return {'schema': 1, 'attempt': self.attempt, 'phase': 'complete',
                        'operation': self.plan['operation'], 'edge_id': self.plan['edge_id']}
            step = journal['steps'][position]
            print('Entry lifecycle: ' + step['action'] + ' ' + step['node'], flush=True)
            result = self.execute(step, status)
            self.core('ack', attempt=self.attempt, position=position, result=result)
        raise RuntimeError('Entry lifecycle exceeded bounded step count; preserve state')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--identities', type=Path, required=True)
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--signing-key', type=Path)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--cancel', action='store_true', help='Cancel the original attempt only before credential delivery')
    args = parser.parse_args()
    config = topology.read_json(args.config)
    topology.fields(config, ('root', 'bootstrap_inventory', 'entry', 'dns', 'tls'))
    node_inventory.validate(config['bootstrap_inventory'])
    topology.fields(config['dns'], ('domain', 'expected', 'token_file'))
    topology.fields(config['entry'], ('id', 'public_ip', 'ssh_host_key', *(name for name in ('origin', 'turn_host') if name in config['entry'])))
    identifier = config['entry']['id']
    if not isinstance(identifier, str) or not re.fullmatch(r'[a-z][a-z0-9-]{0,31}', identifier):
        raise ValueError('Valid entry ID required')
    node_inventory.ipv4(config['entry']['public_ip']); node_inventory.host_key(config['entry']['ssh_host_key'])
    identities = topology.read_json(args.identities)
    if not args.execute and not args.cancel:
        print('Plan input valid; --execute installs the selected entry using pinned SSH.')
        return
    with managed_state.locked(args.state.resolve()) as local:
        path = local / 'operation.json'
        if path.exists() or path.is_symlink():
            record = managed_state.read(path)
            if record['config_sha256'] != role_release.json_digest(config):
                raise ValueError('Use the original config/state to resume; do not replace an uncertain attempt')
        else:
            if args.cancel:
                archived = [managed_state.read(item) for item in local.glob('cancelled-*.json')]
                if any(item.get('config_sha256') == role_release.json_digest(config) for item in archived):
                    print(json.dumps({'schema': 1, 'phase': 'cancelled', 'already_archived': True})); return
                parser.error('--cancel requires an existing original --state directory')
            if args.signing_key is None: parser.error('A new operation requires an operator-local --signing-key')
            bootstrap = config['bootstrap_inventory']
            with host_connection.connection(bootstrap, 'core', identities['core']) as ssh:
                hints = managed_ssh.read_hints(ssh, config['root'])
                web = hints['web'].get(config['entry']['id'], hints['web'][sorted(hints['web'])[0]])
                delivery = entry_package.create(Path(__file__).resolve().parents[1], local / 'source.tar.gz', hints, web)
                ssh_deploy.receive(ssh, config['root'], delivery['commit'], local / 'source.tar.gz')
            # Temporary pre-plan driver reaches only A using the same verified
            # physical assignment; target() is computed from its actual baseline.
            command = ['python3', '-B', config['root'] + '/bundles/' + delivery['source'] + '/infra/entry_core.py',
                       '--root', config['root'], '--source-sha', delivery['source']]
            response = host_connection.execute(bootstrap, 'core', identities['core'], command,
                input=json.dumps({'schema': 1, 'action': 'snapshot'}).encode())
            snapshot = json.loads(response.stdout)
            if snapshot['pending'] is not None and snapshot['pending']['position'] < len(snapshot['pending']['steps']):
                raise ValueError('An entry operation is active; resume its original local state directory')
            public, inventory = target(snapshot['baseline'], config['entry'])
            for name in physical_nodes(inventory): host_connection.parameters(inventory, name, identities[name])
            if route_catalog.public_key(args.signing_key) != snapshot['catalog_key']:
                raise ValueError('Use the installation signing key; never create a replacement key')
            previous = route_catalog.verify(snapshot['catalog'].encode(), snapshot['catalog_key'],
                                            snapshot['baseline']['public'], restoring=True)
            now = int(time.time())
            signed = route_catalog.sign(public, args.signing_key, previous.revision + 1, now, now + 30 * 86400)
            settings = {'catalog': json.dumps(signed, separators=(',', ':')), 'dns_domain': config['dns']['domain'],
                'dns_expected': config['dns']['expected'], 'dns_token_file': config['dns']['token_file'], 'tls': config['tls']}
            record = {'schema': 1, 'operator_id': secrets.token_hex(16), 'config_sha256': role_release.json_digest(config), 'delivery': delivery,
                'baseline': managed_release.store_baseline(local, snapshot['baseline']), 'public': public, 'inventory': inventory, 'settings': entry_settings.store(local / 'settings', settings),
                'attempt': None}
            managed_state.persist(path, record)
        driver = Driver(config['root'], record, identities, local)
        if args.cancel:
            result = driver.cancel()
            archive_id = driver.attempt or ('local-' + record['operator_id'])
            destination = local / ('cancelled-' + archive_id + '.json')
            if destination.exists(): raise ValueError('Local cancelled record already exists')
            os.rename(path, destination)
            os.rename(local / 'source.tar.gz', local / ('source-' + archive_id + '.tar.gz'))
            from tls_material import sync_directory
            sync_directory(local)
        else:
            result = driver.run()
        print(json.dumps(result))


if __name__ == '__main__': main()
