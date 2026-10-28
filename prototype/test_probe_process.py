from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from check_route_tls import run_process


class ProbeProcessTests(unittest.TestCase):
    def test_timeout_stops_the_wrapper_and_its_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child = ('from pathlib import Path; import time; '
                     f'Path({str(root / "started")!r}).touch(); time.sleep(1); '
                     f'Path({str(root / "escaped")!r}).touch()')
            parent = f'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",{child!r}]); time.sleep(5)'
            with self.assertRaises(subprocess.TimeoutExpired):
                run_process([sys.executable, '-c', parent], timeout=.5, capture_output=True)
            self.assertTrue((root / 'started').exists())
            time.sleep(.7)
            self.assertFalse((root / 'escaped').exists())

    def test_return_code_and_captured_output(self):
        result = run_process([sys.executable, '-c', 'print("fixture"); raise SystemExit(3)'],
                             check=False, capture_output=True)
        self.assertEqual((result.returncode, result.stdout), (3, b'fixture\n'))
        with self.assertRaises(subprocess.CalledProcessError):
            run_process([sys.executable, '-c', 'raise SystemExit(3)'])


if __name__ == '__main__': unittest.main()
