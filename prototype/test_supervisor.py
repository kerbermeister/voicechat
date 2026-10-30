import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

spec=importlib.util.spec_from_file_location('supervisor', pathlib.Path(__file__).resolve().parents[1]/'infra/supervise.py')
supervisor=importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

class SupervisorTests(unittest.TestCase):
    def test_cold_start_budget_does_not_extend_runtime_failure_cutoff(self):
        event = Mock()
        event.wait.return_value = False
        child = Mock()
        child.poll.return_value = None
        health = Mock(side_effect=[False, False, True, False, False])
        # Initial readiness after 7s is allowed; a later outage still cuts at 5s.
        with patch.object(supervisor.threading, 'Event', return_value=event), \
                patch.object(supervisor.subprocess, 'Popen', return_value=child), \
                patch.object(supervisor.time, 'monotonic', side_effect=[0, 4, 7, 10, 15]), \
                patch.object(supervisor.signal, 'signal'):
            self.assertEqual(supervisor.run([['synthetic']], health, startup_deadline=30), 1)
        self.assertEqual(health.call_count, 5)
        child.terminate.assert_called_once()

    def test_control_recovery_waits_for_sfu_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = pathlib.Path(directory) / 'ready'
            recovered = pathlib.Path(directory) / 'recovered'
            sfu = [sys.executable, '-c',
                   f'import time,pathlib;time.sleep(.2);pathlib.Path({str(ready)!r}).touch();time.sleep(60)']
            control = [sys.executable, '-c',
                       f'import pathlib;assert pathlib.Path({str(ready)!r}).exists();pathlib.Path({str(recovered)!r}).touch()']
            def sfu_is_ready():
                if not ready.exists(): raise ConnectionRefusedError('SFU still starting')
                return True
            self.assertEqual(supervisor.run([sfu, control], lambda: False,
                             startup_deadline=3, startup_ready=sfu_is_ready), 1)
            self.assertTrue(recovered.exists())

    def test_unready_or_crashed_sfu_never_starts_control(self):
        for crash in (False, True):
            with self.subTest(crash=crash), tempfile.TemporaryDirectory() as directory:
                marker = pathlib.Path(directory) / 'control-started'
                sfu = [sys.executable, '-c', 'pass' if crash else 'import time;time.sleep(60)']
                control = [sys.executable, '-c', f'import pathlib;pathlib.Path({str(marker)!r}).touch()']
                self.assertEqual(supervisor.run([sfu, control], lambda: False,
                                 startup_deadline=.3, startup_ready=lambda: False), 1)
                self.assertFalse(marker.exists())

    def test_shutdown_while_waiting_does_not_start_control(self):
        event, child = Mock(), Mock()
        event.wait.return_value = True
        event.is_set.return_value = False
        child.poll.return_value = None
        with patch.object(supervisor.threading, 'Event', return_value=event), \
                patch.object(supervisor.subprocess, 'Popen', return_value=child) as popen, \
                patch.object(supervisor.signal, 'signal'):
            self.assertEqual(supervisor.run([['sfu'], ['control']], lambda: False,
                             startup_ready=lambda: False), 0)
        popen.assert_called_once_with(['sfu'])
        child.terminate.assert_called_once()

    def test_health_failure_and_crashed_control_terminate_the_sfu(self):
        for crash in (False, True):
            with tempfile.TemporaryDirectory() as directory:
                marker=pathlib.Path(directory)/'sfu.pid'
                child=[sys.executable,'-c',f'import os,time,pathlib;pathlib.Path({str(marker)!r}).write_text(str(os.getpid()));time.sleep(60)']
                control=[sys.executable,'-c','import time;time.sleep(.2)' if crash else 'import time;time.sleep(60)']
                self.assertEqual(supervisor.run([child,control],lambda:False,deadline=.5),1)
                self.assertTrue(marker.exists())
                import os
                with self.assertRaises(ProcessLookupError): os.kill(int(marker.read_text()),0)

if __name__ == '__main__': unittest.main()
