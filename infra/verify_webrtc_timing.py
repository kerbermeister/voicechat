"""Verify timing/sync test evidence against the exact SDK source manifest."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent


def verify_tests(directory, manifest):
    tests = ET.parse(directory / 'timing-tests.xml').getroot()
    cases = tests.findall('.//testcase')
    count = manifest['unit_test_count']
    names = {case.get('classname', '') + '.' + case.get('name', '') for case in cases}
    if (tests.get('tests') != str(count) or tests.get('failures') != '0'
            or tests.get('errors') != '0' or len(cases) != count or len(names) != count
            or tests.findall('.//skipped') or tests.findall('.//failure')
            or tests.findall('.//error') or any(case.get('status') != 'run' for case in cases)):
        raise ValueError(f'All {count} native timing/sync tests must have run and passed')
    before = (directory / 'before-fix.log').read_text()
    if not all(name in names and '[  FAILED  ] ' + name in before
               for name in manifest['regressions']):
        raise ValueError('Every regression must detect the original timing/sync behavior')


def verify(directory, manifest):
    receipt = json.loads((directory / 'build-receipt.json').read_text())
    if any(receipt.get(key) != value for key, value in manifest.items()):
        raise ValueError('Timing evidence does not match the SDK source/toolchain pins')
    if (receipt.get('platform') != 'test' or receipt.get('source_files_verified') is not True
            or receipt.get('shallow_checkout') is not True):
        raise ValueError('Timing evidence lacks the verified source receipt')
    verify_tests(directory, manifest)
    video = ET.parse(directory / 'video-resume-tests.xml').getroot()
    video_cases = video.findall('.//testcase')
    video_names = {case.get('classname', '') + '.' + case.get('name', '') for case in video_cases}
    video_count = manifest['video_recovery_test_count']
    before_video = (directory / 'video-resume-before.log').read_text()
    if (video.get('tests') != str(video_count) or len(video_cases) != video_count
            or len(video_names) != video_count or video.get('failures') != '0'
            or video.get('errors') != '0' or video.findall('.//skipped')
            or video.findall('.//failure') or video.findall('.//error')
            or any(case.get('status') != 'run' for case in video_cases)
            or not all(name in video_names and '[  FAILED  ] ' + name in before_video
                       for name in manifest['video_recovery_regressions'])):
        raise ValueError('Exact video recovery regression evidence is missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    verify(args.directory, json.loads((ROOT / 'webrtc-sdk.json').read_text()))
    print('Exact source/toolchain receipt, negative regressions and all native tests verified')


if __name__ == '__main__':
    main()
