"""Run opt-in UI fixtures, redirecting screenshots without overwriting design history."""
from pathlib import Path
import argparse
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bounded-polish', action='store_true', help='Diagnostic: replace settling with a bounded frame; not equivalent to original test')
options = parser.parse_args()
app = root / 'apps/client'
output = Path('/tmp/voicechat-scenario-captures')
output.mkdir(exist_ok=True)
tests = ['halo_polish_capture_test.dart'] if options.bounded_polish else [
    'auth_capture_test.dart', 'chat_features_visual_test.dart',
    'halo_capture_test.dart', 'halo_polish_capture_test.dart']
with tempfile.TemporaryDirectory(prefix='scenario_audit_', dir=app / 'test') as directory:
    for name in tests:
        source = (app / 'test' / name).read_text()
        for folder, prefix in [('halo-auth', 'auth-'), ('halo-typography', 'type-'), ('halo-polish', 'polish-')]:
            source = source.replace(f'../../docs/design/{folder}/', str(output / prefix))
        source = re.sub(r"import '([^'/]+\.dart)'", r"import '../\1'", source)
        if options.bounded_polish:
            source = source.replace('await tester.pumpAndSettle();', 'await tester.pump(const Duration(milliseconds: 500));')
        (Path(directory) / name).write_text(source)
    result = subprocess.run([str(root / '.prototype/tools/flutter/bin/flutter'), 'test', directory,
        '--reporter', 'expanded', '--dart-define=AUTH_CAPTURE=true',
        '--dart-define=CHAT_FEATURES_CAPTURE=true', '--dart-define=HALO_CAPTURE=true',
        '--dart-define=HALO_POLISH_CAPTURE=true'], cwd=app)
raise SystemExit(result.returncode)
