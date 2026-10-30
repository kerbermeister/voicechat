"""Bounded frozen-source entry lifecycle coordinator on A, reached via pinned SSH."""
import argparse
import json
import os
from pathlib import Path
import platform
import sys

import core_backup_bootstrap
import entry_control
import entry_dns
import entry_journal
import entry_image
import entry_probe
import managed_journal
import managed_release
import managed_state
import network_bootstrap
import node_inventory
import role_bootstrap
import role_release
import topology

MAX_INPUT = 1048576
FIELDS = {'snapshot': (), 'begin': ('baseline', 'public', 'inventory', 'settings'),
          'status': ('attempt',), 'cancel': ('attempt',), 'turn-previous-credential': ('attempt',), 'image-token': ('attempt',), 'secret': ('attempt',), 'certificates': ('attempt',),
          'register': ('attempt', 'identity'), 'ack': ('attempt', 'position', 'result'),
          'dns-observe': ('attempt',), 'dns': ('attempt',), 'commit': ('attempt',), 'finish': ('attempt',)}


def request(raw):
    if len(raw) > MAX_INPUT:
        raise ValueError('Entry coordinator request exceeds its bound')
    value = json.loads(raw, object_pairs_hook=topology.unique_object)
    if not isinstance(value, dict) or not isinstance(value.get('action'), str) or value['action'] not in FIELDS:
        raise ValueError('Known entry coordinator action required')
    topology.fields(value, ('schema', 'action', *FIELDS[value['action']]))
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('Known coordinator schema required')
    if 'attempt' in value and (not isinstance(value['attempt'], str) or not role_release.SHA.fullmatch(value['attempt'])):
        raise ValueError('Exact entry attempt required')
    return value


def operate(value, root, source_sha):
    value = request(json.dumps(value).encode())
    root = managed_journal._root(root)
    if platform.system() != 'Linux' or os.geteuid() != 0:
        raise ValueError('Entry coordinator requires A as root')
    receipt = managed_journal._delivery(root, source_sha)
    if (root / 'bundles' / source_sha).resolve() != Path(__file__).resolve().parents[1]:
        raise ValueError('Run only this exact frozen entry coordinator source')
    with managed_state.locked(root / 'coordinator'):
        pointer, baseline, _ = managed_journal.current(root)
        actual = network_bootstrap.existing(Path('/etc/ssh/ssh_host_ed25519_key.pub'))
        if actual is None or node_inventory.host_key(' '.join(actual.decode().split()[:2])) != baseline['inventory']['core']['ssh_host_key']:
            raise ValueError('Entry coordinator belongs to another pinned A')
        action = value['action']
        active = root / 'entry-lifecycle/current.json'
        if action == 'snapshot':
            saved = entry_journal.load(active.parent) if active.exists() or active.is_symlink() else None
            return {'schema': 1, 'baseline': baseline, 'baseline_sha256': role_release.json_digest(baseline),
                    'catalog_key': entry_control.catalog_key(root), 'catalog': entry_control.published_catalog(root, baseline)[0], 'pending': saved,
                    'candidate': receipt['manifest']}
        if action == 'begin':
            journal = entry_control.begin(root, source_sha, *(value[name] for name in
                ('baseline', 'public', 'inventory', 'settings')))
            return {'schema': 1, 'attempt': journal['attempt'], 'position': journal['position'], 'count': len(journal['steps'])}
        if action == 'cancel': return entry_control.cancel(root, value['attempt'], source_sha)
        journal, path, before, plan, settings, context = entry_control.state(root, value['attempt'])
        if journal['request']['source'] != source_sha:
            raise ValueError('Resume entry admission from its original frozen source')
        attempt = journal['attempt']
        if action == 'status':
            registered = path / 'registration.json'
            return {'schema': 1, 'journal': journal, 'baseline': before, 'plan': plan,
                    'public_keys': context['public_keys'], 'catalog_key': context['catalog_key'],
                    'registration': managed_state.read(registered) if registered.exists() or registered.is_symlink() else None}
        if action == 'image-token': return entry_image.reader(plan['target']['edges'][plan['edge_id']]['images']['web'])
        if action == 'turn-previous-credential': return entry_control.previous_turn_credential(root, attempt)
        if action == 'secret':
            material = entry_control.read_secret(root, attempt)
            # Record possible delivery before returning bytes to the operator.
            managed_state.persist(path / 'credential-delivery.json', {'schema': 1, 'attempt': attempt})
            return material
        if action == 'certificates': return entry_control.certificates(root, attempt)
        if action == 'register': return entry_control.register(root, attempt, value['identity'])
        if action == 'ack':
            updated = entry_control.acknowledge(root, attempt, value['position'], value['result'])
            return {'schema': 1, 'attempt': attempt, 'position': updated['position'], 'count': len(updated['steps'])}
        step = journal['steps'][journal['position']] if journal['position'] < len(journal['steps']) else None
        if action == 'dns':
            if step != {'action': 'dns', 'node': plan['node']}:
                raise ValueError('Verify the new entry before DNS cutover')
            planned = entry_dns.plan(plan['target']['public'], plan['target']['inventory'], plan['edge_id'],
                                     settings['dns_domain'], settings['dns_expected'])
            return entry_dns.cutover(path / 'dns', planned, Path(settings['dns_token_file']))
        if action == 'dns-observe':
            if step != {'action': 'verify-dns', 'node': plan['node']}:
                raise ValueError('Complete DNS cutover before verifying convergence')
            planned = entry_dns.plan(plan['target']['public'], plan['target']['inventory'], plan['edge_id'],
                                     settings['dns_domain'], settings['dns_expected'])
            if any(entry_dns.addresses(host) != planned['target'] for host in [planned['domain'], *planned['names']]):
                raise ValueError('DNS has not converged to the admitted host')
            entry_probe.ready(plan['target']['public'], plan['target']['inventory'], plan['edge_id'])
            return {'schema': 1, 'dns_target_verified': True, 'addresses': planned['target'], 'names': planned['names']}
        if action == 'commit': return entry_control.commit(root, attempt)
        if action == 'finish':
            if step not in ({'action': 'finish', 'node': 'core'}, None):
                raise ValueError('Commit entry readiness before finishing maintenance')
            actual = plan['target']; core = root / 'core'
            managed_release.inspect_role(core, actual['public'], actual['inventory'], actual['core'], subnet=actual['subnet'])
            core_backup_bootstrap.install(core, actual['public'], actual['inventory'], subnet=actual['subnet'])
            return {'schema': 1, 'attempt': attempt, 'maintenance_ready': True, 'phase': 'complete'}
        raise ValueError('Unimplemented coordinator action')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    try:
        result = operate(request(sys.stdin.buffer.read(MAX_INPUT + 1)), args.root, args.source_sha)
    except BlockingIOError:
        parser.exit(75, 'Entry operation is busy; preserve and resume its journal\n')
    if len(json.dumps(result).encode()) > MAX_INPUT:
        raise ValueError('Entry coordinator response exceeds its bound')
    print(json.dumps(result))


if __name__ == '__main__': main()
