"""Run shared routing contracts in local Chrome, using the real infra fixtures.

This does not build crypto assets or exercise real Matrix/media/installation.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter', required=True, type=Path)
    args = parser.parse_args()
    fixtures = {name: json.loads((ROOT / 'infra' / name).read_text())
                for name in ('three-vps.example.json', 'single-vps.example.json')}
    with tempfile.TemporaryDirectory(prefix='voicechat-route-web-') as directory:
        defines = Path(directory) / 'test-defines.json'
        defines.write_text(json.dumps({'ROUTE_TEST_FIXTURES': json.dumps(fixtures)}))
        subprocess.run([str(args.flutter.resolve()), 'test', '--no-pub', '--platform', 'chrome',
                        '--dart-define-from-file', str(defines),
                        *['test/' + name + '_test.dart' for name in (
                            'route_transport', 'route_coordinator', 'media_routes',
                            'routed_livekit_engine', 'route_status_banner')]],
                       cwd=ROOT / 'apps/client', check=True)


if __name__ == '__main__':
    main()
