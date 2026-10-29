from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'infra'))
import cohost_tls_bootstrap
import managed_state
import shared_ingress
import test_shared_cutover


class CohostTLSInstallationTests(unittest.TestCase):
    def setUp(self):
        self.fixture=test_shared_cutover.SharedPortCutoverTests();self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root,self.system=self.fixture.root,self.fixture.system
        self.calls=[];self.interrupt=False

    def source(self,root,**kwargs):
        pointer=managed_state.read(root/'current.json')
        target=shared_ingress.read_plan(root,root/'plans'/pointer['plan'],system_root=self.system)[0]
        return target,root/'unused-source','deploy_caddy_data'

    def command(self,*args):
        self.calls.append(args)
        if self.interrupt and args==('systemctl','enable','--now',cohost_tls_bootstrap.TIMER):
            raise SystemExit('Lost timer enable response')
        return ''

    def install(self,*,locked=False):
        operation=cohost_tls_bootstrap._install_locked if locked else cohost_tls_bootstrap.install
        with patch.object(cohost_tls_bootstrap.cohost_tls,'_source',side_effect=self.source):
            return operation(self.root,execute=self.fixture.execute,run=self.command,system_root=self.system)

    def test_timer_uses_committed_operator_and_never_restarts_application_services(self):
        self.fixture.activate();before=managed_state.read(self.fixture.edge/'state.json')
        target=self.install();self.assertEqual(self.install(),target)
        service=(self.system/'etc/systemd/system'/cohost_tls_bootstrap.SERVICE).read_text()
        self.assertIn(target['operator']['operator_sha256'],service)
        self.assertIn('cohost_tls.py --root '+str(self.root)+' --refresh',service)
        self.assertIn('Restart=on-failure',service)
        self.assertEqual(managed_state.read(self.fixture.edge/'state.json'),before)
        self.assertFalse(any('restart' in args or 'stop' in args for args in self.calls))
        self.assertFalse((self.root/'tls-renewal/pending.json').exists())

    def test_legacy_mode_or_pending_edge_cannot_enable_the_timer(self):
        with self.assertRaisesRegex(ValueError,'Commit public shared'):self.install()
        self.assertEqual(self.calls,[])
        self.fixture.activate()
        path=self.fixture.edge/'state.json';state=managed_state.read(path)
        state['current']=None;managed_state.persist(path,state)
        with self.assertRaisesRegex(ValueError,'Committed cohost edge'):self.install()
        self.assertEqual(self.calls,[])

    def test_full_migration_reuses_ingress_lock(self):
        self.fixture.activate()
        with managed_state.locked(self.root):
            with self.assertRaises(BlockingIOError):self.install()
            self.install(locked=True)

    def test_lost_enable_response_resumes_same_owned_units(self):
        self.fixture.activate();self.interrupt=True
        with self.assertRaises(SystemExit):self.install()
        self.assertTrue((self.root/'tls-renewal/pending.json').exists())
        self.interrupt=False;self.install()
        self.assertFalse((self.root/'tls-renewal/pending.json').exists())

    def test_foreign_unit_and_foreign_receipt_are_never_overwritten(self):
        self.fixture.activate()
        path=self.system/'etc/systemd/system'/cohost_tls_bootstrap.SERVICE
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text('foreign')
        with self.assertRaisesRegex(ValueError,'Unclaimed or modified'):self.install()
        self.assertEqual(path.read_text(),'foreign')
        self.assertEqual(self.calls,[])
        path.unlink();self.install()
        current=self.root/'tls-renewal/current.json';value=managed_state.read(current)
        value['root']='/foreign';managed_state.persist(current,value)
        self.calls.clear()
        with self.assertRaisesRegex(ValueError,'another ingress'):self.install()
        self.assertEqual(self.calls,[])

    def test_post_commit_crash_finishes_same_installation(self):
        self.fixture.activate();persist=managed_state.persist
        def interrupted(path,value):
            persist(path,value)
            if path==self.root/'tls-renewal/current.json':raise SystemExit('Lost commit response')
        with patch.object(managed_state,'persist',side_effect=interrupted):
            with self.assertRaises(SystemExit):self.install()
        self.install()
        self.assertFalse((self.root/'tls-renewal/pending.json').exists())


if __name__=='__main__':unittest.main()
