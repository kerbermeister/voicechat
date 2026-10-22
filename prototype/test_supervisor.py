import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

spec=importlib.util.spec_from_file_location('supervisor', pathlib.Path(__file__).resolve().parents[1]/'infra/supervise.py')
supervisor=importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

class SupervisorTests(unittest.TestCase):
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
