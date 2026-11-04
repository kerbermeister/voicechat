"""Build the pinned WebRTC SDK and test the bounded A/V sync target in CI."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import zipfile

HERE = Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / 'webrtc-sdk.json').read_text())
PATCH = HERE / 'webrtc-bounded-sync.patch'
MIN_FREE = 2_000_000_000
MAC_ARGS = '''enable_libaom=true enable_stripping=true
is_component_build=false is_debug=false rtc_build_examples=false
rtc_enable_protobuf=false rtc_enable_symbol_export=true
rtc_include_dav1d_in_internal_decoder_factory=true rtc_include_tests=false
rtc_libvpx_build_vp9=true rtc_use_h264=false
strip_absolute_paths_from_debug_symbols=true treat_warnings_as_errors=true
use_rtti=true enable_dsyms=false'''
ANDROID_ARGS = '''is_debug=false is_java_debug=false treat_warnings_as_errors=false
rtc_use_h264=false is_component_build=false rtc_build_examples=false
use_rtti=true rtc_build_tools=false rtc_enable_protobuf=false'''


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def run(args, cwd=None, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, check=True, **kwargs)
    if shutil.disk_usage(cwd or Path.cwd()).free < MIN_FREE:
        raise RuntimeError('SDK build must leave at least 2 GB free')


def verify_files(source, hashes):
    for relative, expected in hashes.items():
        if sha(source / relative) != expected:
            raise RuntimeError(f'Unexpected SDK source: {relative}')


def prepare(builder, work, target):
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=builder.parent, text=True).strip()
    if revision != MANIFEST['builder_commit'] or sha(PATCH) != MANIFEST['patch_sha256']:
        raise RuntimeError('SDK builder or patch does not match the reviewed pin')
    if shutil.disk_usage(work).free < 18_000_000_000:
        raise RuntimeError('Use an isolated SDK runner with at least 18 GB free')
    run(['git', 'diff', '--exit-code', 'HEAD', '--', 'build'], cwd=builder.parent)
    tools = work / 'source/depot_tools'
    tools.parent.mkdir(parents=True, exist_ok=True)
    run(['git', 'init', tools])
    run(['git', '-C', tools, 'remote', 'add', 'origin',
         'https://chromium.googlesource.com/chromium/tools/depot_tools.git'])
    run(['git', '-C', tools, 'fetch', '--depth=1', 'origin', MANIFEST['depot_tools_commit']])
    run(['git', '-C', tools, 'checkout', '--detach', 'FETCH_HEAD'])
    os.environ['DEPOT_TOOLS_UPDATE'] = '0'
    os.environ['PYTHONUNBUFFERED'] = '1'
    os.environ['PATH'] = str(tools) + os.pathsep + os.environ['PATH']
    run([tools / 'ensure_bootstrap'], cwd=tools)
    run([tools / 'python-bin/python3', '--version'], cwd=tools)
    source = work / 'source/webrtc/src'
    source.parent.mkdir()
    configuration = (builder / '.gclient').read_text()
    if target == 'android':
        configuration += "target_os = [ 'android' ]\n"
    (source.parent / '.gclient').write_text(configuration)
    run(['git', 'init', source])
    run(['git', '-C', source, 'remote', 'add', 'origin',
         'https://github.com/webrtc-sdk/webrtc.git'])
    run(['git', '-C', source, 'fetch', '--depth=1', 'origin', MANIFEST['webrtc_commit']])
    run(['git', '-C', source, 'checkout', '--detach', 'FETCH_HEAD'])
    # Standard WebRTC CI mode: exact DEPS revisions without Chromium's full history.
    run(['gclient', 'sync', '--no-history', '-D', '--force', '--reset', '--jobs=8'], cwd=source)
    spec = importlib.util.spec_from_file_location('webrtc_builder', builder / 'run.py')
    official = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(official)
    patches = official.PATCHES[target] + (official.TEST_PATCHES if target == 'ubuntu-24.04_x86_64' else [])
    for patch in patches:
        depth, directories = official.PATCH_INFO.get(patch, (1, ['.']))
        official.apply_patch(str(builder / 'patches' / patch), str(source.joinpath(*directories)), depth)
    args = [sys.executable, builder / 'run.py', 'build', target,
            '--source-dir', work / 'source', '--build-dir', work / 'unused',
            '--commit', MANIFEST['webrtc_commit'], '--webrtc-nobuild']
    if target == 'android':
        args.append('--webrtc-nobuild-android-aar')
    elif target == 'ubuntu-24.04_x86_64':
        args.append('--test')
    run(args, cwd=builder)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if head != MANIFEST['webrtc_commit']:
        raise RuntimeError('Unexpected WebRTC source revision')
    verify_files(source, MANIFEST['original_files_sha256'])
    run(['git', 'apply', '--check', PATCH], cwd=source)
    run(['git', 'apply', PATCH], cwd=source)
    verify_files(source, MANIFEST['patched_files_sha256'])
    return source


def unit_tests(source, work, output):
    harness = source / 'voicechat_av_sync_tests'
    harness.mkdir()
    (harness / 'BUILD.gn').write_text('''import("//webrtc.gni")
rtc_test("timing_sync_unittests") {
  testonly = true
  sources = []
  deps = [ "//modules/video_coding/timing:timing_unittests" ]
}
''')
    # GN only loads BUILD.gn files reachable from the root build file.
    root_build = source / 'BUILD.gn'
    root_build.write_text(root_build.read_text() + '''
if (rtc_include_tests) {
  group("voicechat_av_sync_tests") {
    testonly = true
    deps = [ "//voicechat_av_sync_tests:timing_sync_unittests" ]
  }
}
''')
    build = work / 'unit'
    args = '''is_debug=false dcheck_always_on=true symbol_level=0
rtc_include_tests=true rtc_build_examples=false rtc_enable_protobuf=true
rtc_use_pipewire=false rtc_use_h264=false is_component_build=false use_rtti=true'''
    run(['gn', 'gen', build, '--args=' + args], cwd=source)
    timing = source / 'modules/video_coding/timing/timing.cc'
    patched = timing.read_bytes()
    bounded = b'return std::min(timings_.TargetDelay(), timings_.max_playout_delay);'
    if patched.count(bounded) != 1:
        raise RuntimeError('Expected exactly one synchronization-only cap')
    try:
        # Same new API/test, old unbounded behavior: regression must fail first.
        timing.write_bytes(patched.replace(bounded, b'return timings_.TargetDelay();'))
        run(['autoninja', '-C', build, 'timing_sync_unittests', '-j2'], cwd=source)
        before = subprocess.run([str(build / 'timing_sync_unittests'),
            '--gtest_filter=' + MANIFEST['regression_filter']], capture_output=True, text=True)
        (output / 'before-fix.log').write_text(before.stdout + before.stderr)
        failures = ['SyncTargetRespectsMaximumAfterVideoJitter',
                    'SyncTargetPreservesSmallerTargetsAndMinimum']
        if before.returncode != 1 or not all(
                '[  FAILED  ] VCMTimingTest.' + name in before.stdout for name in failures):
            raise RuntimeError('Regression test must detect the old unbounded behavior')
    finally:
        timing.write_bytes(patched)
    verify_files(source, MANIFEST['patched_files_sha256'])
    run(['autoninja', '-C', build, 'timing_sync_unittests', '-j2'], cwd=source)
    after = subprocess.run([str(build / 'timing_sync_unittests'),
        '--gtest_filter=' + MANIFEST['unit_filter'],
        '--gtest_output=xml:' + str(output / 'timing-tests.xml')], capture_output=True, text=True)
    (output / 'after-fix.log').write_text(after.stdout + after.stderr)
    if after.returncode or '[  PASSED  ]' not in after.stdout:
        raise RuntimeError('All timing unit tests must pass after the fix')


def macos(source, work, output):
    frameworks = []
    for cpu in ['arm64', 'x64']:
        build = work / ('macos-' + cpu)
        args = MAC_ARGS + f' target_os="mac" target_cpu="{cpu}" mac_deployment_target="10.15"'
        run(['gn', 'gen', build, '--args=' + args], cwd=source)
        run(['autoninja', '-C', build, 'mac_framework_bundle', '-j2'], cwd=source)
        frameworks.append(build / 'WebRTC.framework')
    universal = work / 'universal/WebRTC.framework'
    shutil.copytree(frameworks[1], universal, symlinks=True)
    run(['lipo', '-create', frameworks[0] / 'WebRTC', frameworks[1] / 'WebRTC',
         '-output', universal / 'WebRTC'])
    run(['lipo', '-verify_arch', 'arm64', 'x86_64', universal / 'WebRTC'])
    package = output / 'WebRTC.xcframework'
    run(['xcodebuild', '-create-xcframework', '-framework', universal, '-output', package])
    shutil.copy2(source / 'LICENSE', package / 'LICENSE')
    framework = package / 'macos-arm64_x86_64/WebRTC.framework'
    binary = framework / 'WebRTC'
    versioned = framework / 'Versions/A/WebRTC'
    if not binary.is_symlink():
        if not versioned.parent.is_dir():
            raise RuntimeError('Unexpected macOS framework layout')
        binary.replace(versioned)
        binary.symlink_to('Versions/Current/WebRTC')
    if not binary.is_file():
        raise RuntimeError('macOS framework binary link is broken')
    run(['zip', '--symlinks', '-r', output / 'WebRTC.xcframework.zip', 'WebRTC.xcframework'], cwd=output)
    return output / 'WebRTC.xcframework.zip'


def android(source, work, output):
    aar = output / 'libwebrtc.aar'
    run([sys.executable, source / 'tools_webrtc/android/build_aar.py',
         '--build-dir', source / 'out/voicechat-aar', '--output', aar,
         '--arch', 'armeabi-v7a', 'arm64-v8a', 'x86_64',
         '--extra-gn-args=' + ANDROID_ARGS, '--extra-ninja-switches=-j2'], cwd=source)
    with zipfile.ZipFile(aar) as archive:
        names = set(archive.namelist())
        for abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']:
            if f'jni/{abi}/libjingle_peerconnection_so.so' not in names:
                raise RuntimeError('Missing native ABI ' + abi)
        if 'classes.jar' not in names:
            raise RuntimeError('SDK Java bindings missing')
    return aar


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['test', 'macos', 'android'])
    parser.add_argument('--builder', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    builder, work, output = args.builder.resolve(), args.work.resolve(), args.output.resolve()
    if args.platform == 'macos' and platform.system() != 'Darwin':
        parser.error('macOS SDK requires a Mac runner')
    work.mkdir(parents=True)
    output.mkdir(parents=True)
    target = {'test': 'ubuntu-24.04_x86_64', 'macos': 'apple', 'android': 'android'}[args.platform]
    source = prepare(builder, work, target)
    artifact = None
    if args.platform == 'test':
        unit_tests(source, work, output)
    else:
        artifact = macos(source, work, output) if args.platform == 'macos' else android(source, work, output)
    verify_files(source, MANIFEST['patched_files_sha256'])
    receipt = {**MANIFEST, 'platform': args.platform,
               'artifact': artifact.name if artifact else None,
               'artifact_sha256': sha(artifact) if artifact else None,
               'source_files_verified': True, 'shallow_checkout': True}
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
