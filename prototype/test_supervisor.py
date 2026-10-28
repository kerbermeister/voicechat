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
