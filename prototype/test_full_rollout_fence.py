from contextlib import nullcontext
from copy import deepcopy
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'infra'))
import core_deploy
import edge_deploy
import managed_state
import role_boot
import role_bootstrap
import role_deploy
import role_release
import test_core_deploy
import test_edge_deploy


def fence(root, manifest):
    owner = {key: manifest[key] for key in ('schema', 'service_id', 'role', 'edge_id', 'identity')}
    path = root / 'role.json'
    if not path.exists(): managed_state.persist(path, owner)
    value = {'schema': 1, 'operation': 'full-rollout', 'root': str(root), 'attempt': 'f' * 64,
             'target': role_release.json_digest(manifest), 'owner': role_release.json_digest(owner)}
    managed_state.persist(root / 'runtime/full-rollout.json', value)
    return value


class FullRolloutFenceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_core_deploy.CoreDeployTests(); self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.deploy(self.fixture.old)
        self.root = self.fixture.root
        self.marker = fence(self.root, self.fixture.new)
        self.fixture.calls.clear()

    def test_nonce_is_bound_to_the_exact_target_and_owned_role_root(self):
        role_deploy.require_rollout_owner(self.root, self.marker['attempt'], self.fixture.new)
        for attempt, manifest in ((None, self.fixture.new), ('e' * 64, self.fixture.new),
                                  (self.marker['attempt'], self.fixture.old), (self.marker['attempt'], None)):
            with self.assertRaisesRegex(ValueError, 'Finish the full rollout'):
                role_deploy.require_rollout_owner(self.root, attempt, manifest)
        original = deepcopy(self.marker)
        for update in ({'root': '/foreign'}, {'schema': True}, {'owner': '0' * 64}, {'attempt': 'bad'}):
            managed_state.persist(self.root / 'runtime/full-rollout.json', {**original, **update})
            with self.assertRaisesRegex(ValueError, 'Invalid or foreign'):
                role_deploy.require_rollout_owner(self.root, original['attempt'], self.fixture.new)

    def operation(self, phase='held'):
        value={'schema':1,'operation':'managed-release','root':str(self.root),
               'attempt':self.marker['attempt'],'owner':self.marker['owner'],
               'before':self.fixture.old,'target':self.fixture.new,'active':self.fixture.new,
               'phase':phase,'result':None if phase=='held' else self.fixture.new}
        managed_state.persist(self.root/'runtime/managed-release.json',value)
        return value

    def test_peer_intent_alone_preserves_services_during_interrupted_fence_creation(self):
        self.operation();(self.root/'runtime/full-rollout.json').unlink()
        with self.assertRaisesRegex(ValueError,'Finish the managed role operation'):
            role_deploy.require_rollout_owner(self.root)
        with patch.object(role_boot,'start') as start, patch.object(role_boot,'notify_ready') as ready:
            self.assertEqual(role_boot.watch(self.root,'core'),0)
            start.assert_not_called();ready.assert_called_once()
        role_boot.stop(self.root,'core',execute=self.fixture.execute)
        activate=Mock()
        with role_bootstrap.monitor_after(self.root,'core',activate=activate):pass
        activate.assert_not_called();self.assertEqual(self.fixture.calls,[])

    def test_peer_intent_must_match_fence_and_release_result(self):
        original=self.operation()
        role_deploy.require_rollout_owner(self.root,self.marker['attempt'],self.fixture.new)
        for update in ({'attempt':'e'*64},{'phase':'released','result':self.fixture.new}):
            managed_state.persist(self.root/'runtime/managed-release.json',{**original,**update})
            with self.assertRaisesRegex(ValueError,'differs from its maintenance fence'):
                role_deploy.require_rollout_owner(self.root,self.marker['attempt'],self.fixture.new)
        for update in ({'owner':'0'*64},{'schema':True},{'root':'/foreign'},{'phase':'released','result':self.fixture.old}):
            managed_state.persist(self.root/'runtime/managed-release.json',{**original,**update})
            with self.assertRaises(ValueError):role_deploy.managed_operation(self.root)

    def test_released_peer_intent_allows_normal_boot_and_cannot_claim_a_missing_fence(self):
        self.operation('released');(self.root/'runtime/full-rollout.json').unlink()
        role_deploy.require_rollout_owner(self.root)
        self.assertFalse(role_deploy.in_maintenance(self.root))
        with self.assertRaisesRegex(ValueError,'has no role maintenance fence'):
            role_deploy.require_rollout_owner(self.root,self.marker['attempt'],self.fixture.new)
        self.assertEqual(role_deploy.rollout_marker(self.root,self.fixture.new,self.marker['attempt']),self.marker)

    def test_separate_core_deploy_backup_sql_and_boot_do_not_touch_containers(self):
        with self.assertRaisesRegex(ValueError, 'Finish the full rollout'):
            self.fixture.deploy(self.fixture.new)
        with self.assertRaisesRegex(ValueError, 'Finish the full rollout'):
            core_deploy.backup_current(self.root, self.fixture.public, self.fixture.inventory,
                execute=self.fixture.execute, check_network=lambda *a, **kw: nullcontext(),
                activate_monitor=lambda *a: None)
        record = core_deploy.record_for(self.root, self.fixture.inventory, self.fixture.new)
        with self.assertRaisesRegex(ValueError, 'Finish the full rollout'):
            core_deploy.migrate_push_routes(self.root, record, 'a' * 64, self.fixture.data_identity,
                execute=self.fixture.execute)
        with self.assertRaisesRegex(ValueError, 'Finish the full rollout'):
            role_boot.start(self.root, 'core', execute=self.fixture.execute)
        role_boot.stop(self.root, 'core', execute=self.fixture.execute)
        self.assertEqual(self.fixture.calls, [])

    def test_owned_core_apply_keeps_maintenance_fence_and_defers_monitor(self):
        activate = Mock()
        core_deploy.deploy(self.root, self.fixture.public, self.fixture.inventory, self.fixture.new,
            execute=self.fixture.execute, check_network=lambda *a, **kw: nullcontext(),
            check_health=self.fixture.healthy, create_backup=self.fixture.backup, check_boot=lambda *a: None,
            identify_data=lambda *a, **kw: self.fixture.data_identity.copy(), activate_monitor=activate,
            rollout_attempt=self.marker['attempt'])
        self.assertEqual(self.fixture.state()['current']['manifest'], self.fixture.new)
        self.assertEqual(role_deploy.pending_rollout(self.root), self.marker)
        activate.assert_not_called()
        (self.root / 'runtime/full-rollout.json').unlink()
        with self.assertRaisesRegex(ValueError, 'has no role maintenance fence'):
            role_deploy.require_rollout_owner(self.root, self.marker['attempt'], self.fixture.new)
        with role_bootstrap.monitor_after(self.root, 'core', activate=activate): pass
        activate.assert_called_once()

    def test_monitor_on_boot_exits_cleanly_without_starting_or_stopping_services(self):
        with patch.object(role_boot, 'start') as start, patch.object(role_boot, 'stop') as stop, \
                patch.object(role_boot, 'notify_ready') as ready, patch.object(role_boot.subprocess, 'Popen') as process:
            self.assertEqual(role_boot.watch(self.root, 'core'), 0)
            start.assert_not_called(); stop.assert_not_called(); process.assert_not_called()
            ready.assert_called_once()

    def test_running_monitor_leaves_full_shutdown_to_the_coordinator(self):
        waiter = Mock(); waiter.poll.return_value = None
        with patch.object(role_deploy, 'pending_rollout', side_effect=[None, self.marker]), \
                patch.object(role_boot, 'start', return_value={'manifest': {}}), \
                patch.object(core_deploy, 'compose', return_value=b'pg\nsynapse\ncontrol\n'), \
                patch.object(role_boot, 'notify_ready'), patch.object(role_boot, 'stop') as stop, \
                patch.object(role_boot.subprocess, 'Popen', return_value=waiter):
            self.assertEqual(role_boot.watch(self.root, 'core'), 0)
            stop.assert_not_called()
            self.assertEqual(waiter.terminate.call_count, 3)

    def test_edge_apply_requires_its_own_exact_full_target(self):
        edge = test_edge_deploy.EdgeDeployTests(); edge.setUp(); self.addCleanup(edge.doCleanups)
        edge.deploy(edge.old); marker = fence(edge.root, edge.new); edge.calls.clear()
        with self.assertRaisesRegex(ValueError, 'Finish the full rollout'): edge.deploy(edge.new)
        self.assertEqual(edge.calls, [])
        activate = Mock()
        edge_deploy.deploy(edge.root, edge.public, edge.inventory, edge.new, edge.core,
            execute=edge.execute, check_boot=lambda *a: None, activate_monitor=activate,
            check_network=lambda *a, **kw: nullcontext(), check_health=edge.health,
            rollout_attempt=marker['attempt'])
        activate.assert_not_called()
        self.assertEqual(edge.state()['current']['manifest'], edge.new)


if __name__ == '__main__': unittest.main()
