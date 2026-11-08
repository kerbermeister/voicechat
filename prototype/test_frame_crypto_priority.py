"""Exercise the Android scheduling policy with controlled OS responses."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def priority_function(patch):
    added = '\n'.join(line[1:] for line in patch.splitlines()
                      if line.startswith('+') and not line.startswith('+++'))
    start = added.index('int SetFrameCryptoThreadPriority(bool audio)')
    first = added.index('{', start)
    depth = 1
    for end in range(first + 1, len(added)):
        depth += (added[end] == '{') - (added[end] == '}')
        if depth == 0:
            return added[start:end + 1]
    raise ValueError('Unterminated crypto priority policy')


def run_priority_contract(policy):
    compiler = shutil.which('c++')
    if compiler is None:
        raise RuntimeError('The native policy contract needs a C++ compiler')
    source = '''#include <cassert>
#include <cerrno>
#define WEBRTC_ANDROID 1
using id_t = unsigned;
#ifndef PRIO_PROCESS
#define PRIO_PROCESS 0
#endif
static int current, read_error, write_error, writes;
int gettid() { return 42; }
int getpriority(int which, id_t thread) {
  assert(which == PRIO_PROCESS && thread == 42);
  errno = read_error;
  return current;
}
int setpriority(int which, id_t thread, int priority) {
  assert(which == PRIO_PROCESS && thread == 42);
  ++writes;
  if (write_error) { errno = write_error; return -1; }
  current = priority;
  return 0;
}
''' + policy + '''
int main() {
  struct Case { int initial; bool audio; int read_error; int write_error;
                int expected; int calls; int status; };
  const Case cases[] = {
    {-20, true, 0, 0, -20, 0, 0},
    {-16, true, 0, 0, -16, 0, 0},
    {-10, false, 0, 0, -10, 0, 0},
    {-10, true, 0, 0, -16, 1, 0},
    {0, false, 0, 0, -4, 1, 0},
    {-1, false, 0, 0, -4, 1, 0},
    {0, true, EIO, 0, 0, 0, EIO},
    {0, true, 0, EPERM, 0, 1, EPERM},
  };
  for (const auto& value : cases) {
    current = value.initial;
    read_error = value.read_error;
    write_error = value.write_error;
    writes = 0;
    errno = EINVAL;  // A valid getpriority(-1) must clear an older error.
    assert(SetFrameCryptoThreadPriority(value.audio) == value.status);
    assert(current == value.expected && writes == value.calls);
  }
}
'''
    with tempfile.TemporaryDirectory(prefix='crypto-priority-contract-') as directory:
        work = Path(directory)
        path = work / 'priority.cc'
        path.write_text(source)
        subprocess.run([compiler, '-std=c++17', path, '-o', work / 'priority'],
                       check=True, capture_output=True)
        return subprocess.run([work / 'priority'], capture_output=True)


class FrameCryptoPriorityTest(unittest.TestCase):
    def test_android_priority_preserves_stronger_threads_and_os_errors(self):
        policy = priority_function((ROOT / 'infra/webrtc-bounded-sync.patch').read_text())
        result = run_priority_contract(policy)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
