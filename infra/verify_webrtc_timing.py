"""Verify reusable timing-test evidence against the exact SDK source manifest."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
REGRESSIONS = (
    'SyncDelayUsesCurrentDelayAfterVideoJitter',
    'SyncDelayRespectsBoundsAndAudioDeviceMinimum',
    'SyncDelayUsesLowLatencyRenderingPath',
)


def verify(directory, manifest):
    receipt = json.loads((directory / 'build-receipt.json').read_text())
    if any(receipt.get(key) != value for key, value in manifest.items()):
        raise ValueError('Timing evidence does not match the SDK source/toolchain pins')
    if (receipt.get('platform') != 'test' or receipt.get('source_files_verified') is not True
            or receipt.get('shallow_checkout') is not True):
        raise ValueError('Timing evidence lacks the verified source receipt')
    tests = ET.parse(directory / 'timing-tests.xml').getroot()
    cases = tests.findall('.//testcase')
    if (tests.get('tests') != '21' or tests.get('failures') != '0' or tests.get('errors') != '0'
            or len(cases) != 21 or tests.findall('.//skipped') or tests.findall('.//failure')
            or tests.findall('.//error') or any(case.get('status') == 'notrun' for case in cases)):
        raise ValueError('All 21 native timing tests must have run and passed')
    names = {case.get('name') for case in cases if case.get('classname') == 'VCMTimingTest'}
    before = (directory / 'before-fix.log').read_text()
    if not all(name in names and '[  FAILED  ] VCMTimingTest.' + name in before for name in REGRESSIONS):
        raise ValueError('All three regressions must detect the old getter behavior')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    verify(args.directory, json.loads((ROOT / 'webrtc-sdk.json').read_text()))
    print('Exact source/toolchain receipt, 3 negative regressions and 21 passing native tests verified')


if __name__ == '__main__':
    main()
