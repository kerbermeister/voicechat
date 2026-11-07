"""Check native renderer freshness and retained buffers in a built macOS app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def check(app):
    frameworks = app / 'Contents/Frameworks'
    plugin = frameworks / 'flutter_webrtc.framework'
    binary = plugin / 'Versions/A/flutter_webrtc'
    if not binary.is_file():
        raise ValueError('Candidate flutter_webrtc framework is missing')
    source = Path(__file__).with_name('macos_renderer_probe.m')
    with tempfile.TemporaryDirectory(prefix='voicechat-renderer-') as directory:
        executable = Path(directory) / 'renderer-probe'
        subprocess.run([
            'xcrun', 'clang', '-fobjc-arc', '-fmodules', '-Wall', '-Wextra', '-Werror',
            '-framework', 'Foundation', '-framework', 'CoreVideo', '-framework', 'CoreGraphics',
            '-Wl,-rpath,' + str(frameworks), source, '-o', executable,
        ], check=True, capture_output=True, text=True)
        result = subprocess.run([executable, plugin], capture_output=True, text=True)
        report = json.loads(result.stdout)
    required = ('latest_frame_wins', 'retained_buffer_immutable', 'next_frame_correct',
                'notifications_coalesced', 'retained_buffer_survives_dispose',
                'track_change_discards_previous_frame', 'size_change_correct')
    assert report['production_renderer_component'] and report['synthetic_frames']
    assert report['physical_display_measured'] is False
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    with binary.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {**report, 'pass': result.returncode == 0 and
            all(report[field] is True for field in required),
            'app_build': info['CFBundleVersion'],
            'app_version': info['CFBundleShortVersionString'],
            'renderer_framework_sha256': digest}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = check(args.app.resolve())
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2)
    print(json.dumps(report))
    raise SystemExit(0 if report['pass'] else 1)
