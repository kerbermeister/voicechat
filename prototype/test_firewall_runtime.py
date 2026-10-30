from copy import deepcopy
import fcntl
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import firewall_config
import firewall_runtime
import managed_state
from test_node_inventory import fixture, key


class Firewall:
    def __init__(self, value):
        self.name, self.owner = firewall_config.identity(value['inventory'], value['node'])
        self.tables = [{'family': 'inet', 'name': 'foreign', 'comment': 'unrelated'}]
        self.applied = []
        self.fail_check = False
        self.fail_apply = False

    def run(self, *args):
        if args == ('nft', '-j', 'list', 'tables'):
            return json.dumps({'nftables': [{'table': item} for item in self.tables]})
        if args == ('nft', 'list', 'table', 'inet', self.name):
            owner = next(item['comment'] for item in self.tables if item['name'] == self.name)
            return f'table inet {self.name} {{\n  comment "{owner}"\n}}'
        if args[:3] == ('nft', '--check', '--file'):
            if self.fail_check: raise RuntimeError('Invalid kernel configuration')
            return ''
        if args[:2] == ('nft', '--file'):
            if self.fail_apply: raise RuntimeError('Interrupted before kernel apply')
            self.applied.append(Path(args[-1]).read_text())
            self.tables = [self.tables[0], {'family': 'inet', 'name': self.name, 'comment': self.owner}]
            return ''
        raise AssertionError(args)


class FirewallRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'firewall'
        self.value = {'schema': 1, 'inventory': fixture(), 'node': 'core', 'edge_subnet': '10.241.0.0/28'}
        self.kernel = Firewall(self.value)

    def apply(self, value):
        firewall_runtime.reconcile(self.root, value, run=self.kernel.run)

    def test_repeat_and_recreate_preserve_foreign_tables(self):
        self.apply(self.value)
        self.assertNotIn('delete table', self.kernel.applied[-1])
        stamp = (self.root / 'desired.json').stat().st_mtime_ns
        self.apply(None)
        self.assertEqual((self.root / 'desired.json').stat().st_mtime_ns, stamp)
        self.assertTrue(self.kernel.applied[-1].startswith('delete table inet ' + self.kernel.name))
        self.assertNotIn('foreign', self.kernel.applied[-1])
        self.kernel.tables.pop()
        self.apply(None)
        self.assertNotIn('delete table', self.kernel.applied[-1])
        self.assertFalse(list(self.root.glob('.nft-*')))

    def test_invalid_kernel_check_does_not_commit_but_interrupted_apply_resumes_revocation(self):
        self.kernel.fail_check = True
        with self.assertRaises(RuntimeError): self.apply(self.value)
        self.assertFalse((self.root / 'desired.json').exists())
        self.kernel.fail_check = False
        self.apply(self.value)
        retired = deepcopy(self.value)
        retired['inventory']['edges'].pop()
        self.kernel.fail_apply = True
        with self.assertRaises(RuntimeError): self.apply(retired)
        self.assertEqual(managed_state.read(self.root / 'desired.json'), retired)
        self.kernel.fail_apply = False
        self.apply(None)
        self.assertNotIn('192.0.2.12', self.kernel.applied[-1])

    def test_foreign_or_unclaimed_table_is_never_adopted(self):
        self.kernel.tables.append({'family': 'inet', 'name': self.kernel.name, 'comment': self.kernel.owner})
        with self.assertRaises(ValueError): self.apply(self.value)
        self.assertFalse((self.root / 'desired.json').exists())
        self.kernel.tables.pop()
        self.apply(self.value)
        self.kernel.tables[-1]['comment'] = 'foreign'
        with self.assertRaises(ValueError): self.apply(None)
        self.assertEqual(len(self.kernel.applied), 1)

    def test_host_identity_subnet_and_generation_changes_require_migration(self):
        self.apply(self.value)
        for field, value in (('node', 'edge-b'), ('edge_subnet', '10.242.0.0/28')):
            changed = {**self.value, field: value}
            with self.assertRaises(ValueError): self.apply(changed)
        changed = deepcopy(self.value)
        changed['inventory']['edges'][0].update(generation=2, ssh_host_key=key(9), public_ip='192.0.2.13')
        self.apply(changed)
        with self.assertRaises(ValueError): self.apply(self.value)
        changed['inventory']['core'].update(generation=2, ssh_host_key=key(8))
        with self.assertRaises(ValueError): self.apply(changed)

    def test_unsafe_state_and_concurrent_apply_fail_before_mutation(self):
        self.apply(self.value)
        with (self.root / 'apply.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError): self.apply(None)
        path = self.root / 'desired.json'
        path.chmod(0o644)
        with self.assertRaises(ValueError): self.apply(None)
        path.chmod(0o600)
        path.write_text('{"schema":1,"schema":1}')
        with self.assertRaises(ValueError): self.apply(None)
        path.unlink(); path.symlink_to(self.root / 'absent')
        with self.assertRaises(OSError): self.apply(None)
        self.assertEqual(len(self.kernel.applied), 1)
