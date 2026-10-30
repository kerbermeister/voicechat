from copy import deepcopy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import entry_dns
import topology
from test_node_inventory import fixture


class EntryDnsTests(unittest.TestCase):
    def setUp(self):
        self.public = topology.load(ROOT / 'infra/three-vps.example.json')
        self.public['edges'][1].update(origin='https://entry-c.duckdns.org', turn_host='turn.entry-c.duckdns.org')
        self.inventory = fixture()
        self.request = entry_dns.plan(self.public, self.inventory, 'c', 'entry-c.duckdns.org', ['192.0.2.20'])
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.records = self.request['expected']
        self.writes = []

    def write(self, domain, address, token):
        self.writes.append((domain, address)); self.records = [address]

    def cutover(self):
        return entry_dns.cutover(self.directory, self.request, Path('/central/secret'),
                                 lookup=lambda _: self.records, write=self.write)

    def test_cutover_lost_response_and_repeat_never_reverts_old_address(self):
        self.assertEqual(self.cutover()['phase'], 'complete')
        self.assertEqual(self.cutover()['addresses'], ['192.0.2.12'])
        self.assertEqual(self.writes, [('entry-c.duckdns.org', '192.0.2.12')])
        self.assertFalse(self.cutover()['atomic_provider_cas'])
        self.assertEqual(len(self.writes), 1)
        self.assertNotIn('secret', (self.directory / 'cutover.json').read_text())

    def test_stale_or_ipv6_records_reject_without_write(self):
        for records in (['192.0.2.99'], ['192.0.2.20', '2001:db8::1']):
            self.records = records
            with self.assertRaisesRegex(ValueError, 'expected value'): self.cutover()
        self.assertEqual(self.writes, [])
        self.assertFalse((self.directory / 'cutover.json').exists())

    def test_completed_cutover_does_not_fight_a_later_dns_writer(self):
        self.cutover(); self.records = self.request['expected']
        with self.assertRaisesRegex(ValueError, 'drifted'): self.cutover()
        self.assertEqual(len(self.writes), 1)

    def test_pending_retry_after_lost_update_reply_accepts_only_its_target(self):
        def lost(*args):
            self.write(*args); raise ConnectionError('reply lost')
        with self.assertRaises(ConnectionError):
            entry_dns.cutover(self.directory, self.request, Path('/central/secret'),
                              lookup=lambda _: self.records, write=lost)
        self.assertEqual(self.cutover()['phase'], 'complete')
        self.assertEqual(len(self.writes), 1)
        changed = deepcopy(self.request); changed['target'] = ['192.0.2.90']
        with self.assertRaisesRegex(ValueError, 'same DNS'):
            entry_dns.cutover(self.directory, changed, Path('/central/secret'), lookup=lambda _: self.records, write=self.write)

    def test_rejects_shared_canonical_domain_before_io(self):
        self.public['canonical_origin'] = 'https://entry-c.duckdns.org'
        self.public['web_origins'][0] = self.public['canonical_origin']
        with self.assertRaises(ValueError):
            entry_dns.plan(self.public, self.inventory, 'c', 'entry-c.duckdns.org', [])

    def test_provider_failure_redacts_secret_url_and_disables_proxy_redirects(self):
        token = '12345678-1234-1234-1234-123456789abc'
        with patch.object(entry_dns.tls_material, 'read_material', return_value=token.encode()), \
             patch.object(entry_dns.urllib.request, 'build_opener') as builder:
            builder.return_value.open.side_effect = RuntimeError('https://provider/?token=' + token)
            with self.assertRaises(ValueError) as error:
                entry_dns.update('entry-c.duckdns.org', '192.0.2.12', Path('/secret'))
        self.assertNotIn(token, str(error.exception))
        self.assertNotIn('https', str(error.exception))
        self.assertIsNone(error.exception.__cause__)


if __name__ == '__main__': unittest.main()
