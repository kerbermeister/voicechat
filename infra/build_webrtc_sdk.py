"""Build the pinned WebRTC SDK and test the bounded A/V sync target in CI."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import zipfile

from verify_native_playout_policy import verify as verify_playout_policy

HERE = Path(__file__).resolve().parent
MANIFEST = json.loads((HERE / 'webrtc-sdk.json').read_text())
PATCH = HERE / 'webrtc-bounded-sync.patch'
MIN_FREE = 2_000_000_000
MAC_ARGS = '''enable_libaom=true enable_stripping=true
is_component_build=false is_debug=false rtc_build_examples=false
rtc_enable_protobuf=false rtc_enable_symbol_export=true
rtc_include_dav1d_in_internal_decoder_factory=true rtc_include_tests=false
rtc_libvpx_build_vp9=true rtc_use_h264=false
treat_warnings_as_errors=true
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
rtc_library("sync_production") {
  sources = [
    "//video/rtp_streams_synchronizer2.cc",
    "//video/rtp_streams_synchronizer2.h",
    "//video/stream_synchronization.cc",
    "//video/stream_synchronization.h",
    "//call/syncable.cc",
    "//call/syncable.h",
  ]
  deps = [
    "//api/environment",
    "//api:sequence_checker",
    "//api/task_queue",
    "//api/units:time_delta",
    "//api/units:timestamp",
    "//rtc_base:checks",
    "//rtc_base:logging",
    "//rtc_base:rtp_to_ntp_estimator",
    "//rtc_base:macromagic",
    "//rtc_base:event_tracer",
    "//rtc_base/system:no_unique_address",
    "//rtc_base/task_utils:repeating_task",
    "//system_wrappers",
  ]
}
rtc_library("sync_unittests") {
  testonly = true
  sources = [ "//video/stream_synchronization_unittest.cc" ]
  deps = [
    ":sync_production",
    "//api/environment:environment_factory",
    "//test:test_support",
    "//test/time_controller:time_controller",
  ]
}
rtc_test("timing_sync_unittests") {
  testonly = true
  sources = []
  deps = [
    ":sync_unittests",
    "//api/crypto:crypto_unittests",
    "//common_video",
    "//modules/video_coding/timing:timing_unittests",
    "//modules/rtp_rtcp:rtp_video_header",
    "//rtc_base:byte_buffer",
    "//rtc_base:crypto_random",
  ]
}
rtc_test("video_resume_unittests") {
  testonly = true
  sources = [
    "//modules/video_coding/nack_requester_unittest.cc",
    "//video/render/incoming_video_stream_unittest.cc",
  ]
  deps = [
    "//api:make_ref_counted",
    "//api:scoped_refptr",
    "//api/environment:environment_factory",
    "//api/task_queue",
    "//api/units:time_delta",
    "//api/units:timestamp",
    "//api/video:video_frame",
    "//modules:module_api",
    "//modules/video_coding:nack_requester",
    "//rtc_base:checks",
    "//system_wrappers",
    "//test:create_test_field_trials",
    "//test:run_loop",
    "//test:test_support",
    "//test/time_controller:time_controller",
    "//video:rtp_video_stream_receiver2_unittest",
    "//video/render:incoming_video_stream",
  ]
}
''')
    # GN only loads BUILD.gn files reachable from the root build file.
    root_build = source / 'BUILD.gn'
    root_build.write_text(root_build.read_text() + '''
if (rtc_include_tests) {
  group("voicechat_av_sync_tests") {
    testonly = true
    deps = [
      "//voicechat_av_sync_tests:timing_sync_unittests",
      "//voicechat_av_sync_tests:video_resume_unittests",
    ]
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
    synchronizer = source / 'video/rtp_streams_synchronizer2.cc'
    patched_sync = synchronizer.read_bytes()
    sync_header = synchronizer.with_suffix('.h')
    patched_header = sync_header.read_bytes()
    extrapolator_header = source / 'modules/video_coding/timing/timestamp_extrapolator.h'
    patched_extrapolator_header = extrapolator_header.read_bytes()
    cryptor = source / 'api/crypto/frame_crypto_transformer.cc'
    patched_cryptor = cryptor.read_bytes()
    bounded = b'  if (UseLowLatencyRendering()) {\n    return TimeDelta::Zero();\n  }\n  return std::clamp(sync_playout_delay.value_or(current_delay),\n                    min_playout_delay, max_playout_delay);'
    if patched.count(bounded) != 1:
        raise RuntimeError('Expected exactly one effective render-delay calculation')
    receive_relative = b'  return std::max(TimeDelta::Zero(),\n                  RenderTime(rtp_timestamp, receive_time) - receive_time);'
    if patched.count(receive_relative) != 1:
        raise RuntimeError('Expected exactly one receive-relative render delay')
    try:
        # Same new API/test, old unbounded behavior: regression must fail first.
        before_timing = patched.replace(bounded, b'  return TargetDelay();')
        before_timing = before_timing.replace(receive_relative,
                                              b'  return GetTimings().CurrentDelay();')
        future_guard = b'constexpr TimeDelta kMaxFrameClockLead = TimeDelta::Millis(250);'
        if before_timing.count(future_guard) != 1:
            raise RuntimeError('Expected exactly one RTP arrival-clock guard')
        before_timing = before_timing.replace(future_guard,
            b'constexpr TimeDelta kMaxFrameClockLead = TimeDelta::PlusInfinity();')
        timing.write_bytes(before_timing)
        for path in [synchronizer, sync_header, extrapolator_header, cryptor]:
            path.write_bytes(subprocess.check_output(
                ['git', 'show', MANIFEST['webrtc_commit'] + ':' + path.relative_to(source).as_posix()],
                cwd=source))
        run(['autoninja', '-C', build, 'timing_sync_unittests', '-j2'], cwd=source)
        before = subprocess.run([str(build / 'timing_sync_unittests'),
            '--gtest_filter=' + MANIFEST['regression_filter']], capture_output=True, text=True)
        (output / 'before-fix.log').write_text(before.stdout + before.stderr)
        if before.returncode != 1 or not all(
                '[  FAILED  ] ' + name in before.stdout for name in MANIFEST['regressions']):
            raise RuntimeError('Each regression must detect the original timing/sync behavior')
    finally:
        timing.write_bytes(patched)
        synchronizer.write_bytes(patched_sync)
        sync_header.write_bytes(patched_header)
        extrapolator_header.write_bytes(patched_extrapolator_header)
        cryptor.write_bytes(patched_cryptor)
    verify_files(source, MANIFEST['patched_files_sha256'])
    sync_render_guard = b'constexpr TimeDelta kMaxSyncRenderLead = TimeDelta::Millis(250);'
    if patched.count(sync_render_guard) != 1:
        raise RuntimeError('Expected exactly one final synchronization deadline guard')
    render_regression = 'VCMTimingTest.SyncDelayRejectsUnreasonableFrameDeadline'
    try:
        timing.write_bytes(patched.replace(sync_render_guard,
            b'constexpr TimeDelta kMaxSyncRenderLead = TimeDelta::PlusInfinity();'))
        run(['autoninja', '-C', build, 'timing_sync_unittests', '-j2'], cwd=source)
        before_render = subprocess.run([str(build / 'timing_sync_unittests'),
            '--gtest_filter=' + render_regression], capture_output=True, text=True)
        (output / 'before-render-lead.log').write_text(before_render.stdout + before_render.stderr)
        if before_render.returncode != 1 or '[  FAILED  ] ' + render_regression not in before_render.stdout:
            raise RuntimeError('Final render-deadline regression must fail with the former policy')
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
    spec = importlib.util.spec_from_file_location('timing_evidence', HERE / 'verify_webrtc_timing.py')
    evidence = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(evidence)
    evidence.verify_tests(output, MANIFEST)

    recovery_files = [
        'modules/video_coding/nack_requester.cc',
        'modules/video_coding/nack_requester.h',
        'video/rtp_video_stream_receiver2.cc',
        'video/render/video_render_frames.cc',
        'video/render/incoming_video_stream.cc',
        'video/render/incoming_video_stream.h',
    ]
    patched_recovery = {name: (source / name).read_bytes() for name in recovery_files}
    regressions = MANIFEST['video_recovery_regressions']
    binary = build / 'video_resume_unittests'
    try:
        for name in recovery_files:
            (source / name).write_bytes(subprocess.check_output(
                ['git', 'show', MANIFEST['webrtc_commit'] + ':' + name], cwd=source))
        run(['autoninja', '-C', build, binary.name, '-j2'], cwd=source)
        before = subprocess.run([str(binary), '--gtest_filter=' + ':'.join(regressions)],
                                capture_output=True, text=True)
        (output / 'video-resume-before.log').write_text(before.stdout + before.stderr)
        if before.returncode != 1 or not all(
                '[  FAILED  ] ' + name in before.stdout for name in regressions):
            raise RuntimeError('Each video recovery regression must reproduce the old behavior')
    finally:
        for name, content in patched_recovery.items():
            (source / name).write_bytes(content)
    verify_files(source, MANIFEST['patched_files_sha256'])
    run(['autoninja', '-C', build, binary.name, '-j2'], cwd=source)
    run([binary, '--gtest_filter=RtpVideoStreamReceiver2Test.*:IncomingVideoStreamTest.*:'
         'TestNackRequester.VideoResume*',
         '--gtest_output=xml:' + str(output / 'video-resume-tests.xml')], cwd=source)


def macos(source, work, output):
    # The published macOS application is arm64; build its actual SDK architecture.
    build = work / 'macos-arm64'
    args = MAC_ARGS + ' target_os="mac" target_cpu="arm64" mac_deployment_target="10.15"'
    run(['gn', 'gen', build, '--args=' + args], cwd=source)
    run(['autoninja', '-C', build, 'mac_framework_bundle', '-j2'], cwd=source)
    verify_files(source, MANIFEST['patched_files_sha256'])
    framework = build / 'WebRTC.framework'
    run(['lipo', framework / 'WebRTC', '-verify_arch', 'arm64'])
    compiled = output / 'macos-compiled-framework.zip'
    run(['zip', '--symlinks', '-r', compiled, 'WebRTC.framework'], cwd=build)
    (output / 'compiled-framework-receipt.json').write_text(json.dumps({
        **MANIFEST, 'platform': 'macos', 'architectures': ['arm64'],
        'artifact': compiled.name, 'artifact_sha256': sha(compiled),
        'source_files_verified': True, 'shallow_checkout': True}, indent=2) + '\n')
    run([sys.executable, source / 'tools_webrtc/libs/generate_licenses.py',
         '--target', 'sdk:mac_framework_objc', output, build], cwd=source)
    package = output / 'WebRTC.xcframework'
    run(['xcodebuild', '-create-xcframework', '-framework', framework, '-output', package])
    shutil.copy2(source / 'LICENSE', package / 'LICENSE')
    shutil.copy2(output / 'LICENSE.md', package / 'THIRD-PARTY-NOTICES.md')
    framework = package / 'macos-arm64/WebRTC.framework'
    binary = framework / 'WebRTC'
    versioned = framework / 'Versions/A/WebRTC'
    if not binary.is_symlink():
        if not versioned.parent.is_dir():
            raise RuntimeError('Unexpected macOS framework layout')
        binary.replace(versioned)
        binary.symlink_to('Versions/Current/WebRTC')
    if not binary.is_file():
        raise RuntimeError('macOS framework binary link is broken')
    run(['lipo', binary, '-verify_arch', 'arm64'])
    resources = framework / 'Versions/A/Resources'
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / 'LICENSE', resources / 'WebRTC-LICENSE')
    shutil.copy2(output / 'LICENSE.md', resources / 'WebRTC-THIRD-PARTY-NOTICES.md')
    run(['codesign', '--force', '--sign', '-', '--timestamp=none', framework])
    run(['zip', '--symlinks', '-r', output / 'WebRTC.xcframework.zip', 'WebRTC.xcframework'], cwd=output)
    return output / 'WebRTC.xcframework.zip'


def android(source, work, output):
    aar = output / 'libwebrtc.aar'
    build_root = source / 'out/voicechat-aar'
    run([sys.executable, source / 'tools_webrtc/android/build_aar.py',
         '--build-dir', build_root, '--output', aar,
         '--arch', 'armeabi-v7a', 'arm64-v8a', 'x86_64',
         '--extra-gn-args=' + ANDROID_ARGS, '--extra-ninja-switches=-local_jobs=2'], cwd=source)
    with zipfile.ZipFile(aar) as archive:
        names = set(archive.namelist())
        for abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']:
            if f'jni/{abi}/libjingle_peerconnection_so.so' not in names:
                raise RuntimeError('Missing native ABI ' + abi)
        if 'classes.jar' not in names:
            raise RuntimeError('SDK Java bindings missing')
    with zipfile.ZipFile(aar, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, path in [('LICENSE', source / 'LICENSE'),
                           ('THIRD-PARTY-NOTICES.md', output / 'LICENSE.md')]:
            destination = 'assets/webrtc-sdk/' + name
            if destination in archive.namelist():
                raise RuntimeError('Duplicate SDK license asset')
            archive.write(path, destination)
    test_build = build_root / 'arm64-v8a'
    gn_args = test_build / 'args.gn'
    configured, count = re.subn(r'\brtc_include_tests\s*=\s*false\b',
                                'rtc_include_tests = true', gn_args.read_text())
    if count != 1:
        raise RuntimeError('Expected the Android AAR test flag')
    gn_args.write_text(configured)
    run(['gn', 'gen', test_build], cwd=source)
    run(['autoninja', '-C', test_build, 'android_sdk_junit_tests', '-local_jobs=2'], cwd=source)
    run([test_build / 'bin/run_android_sdk_junit_tests', '-f',
         'org.webrtc.AndroidVideoDecoderTest.testReportsStalledOutputOnlyDuringContinuousInput',
         '--json-results-file', output / 'android-decoder-test-results.json'], cwd=source)
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
    policy = None
    if artifact is not None:
        report = output / 'native-playout-policy-tests.json'
        binary = (output / 'WebRTC.xcframework/macos-arm64/WebRTC.framework/WebRTC'
                  if args.platform == 'macos' else None)
        policy = verify_playout_policy(source, args.platform, report, artifact, binary)
        if policy['pass_count'] != MANIFEST['platform_policy_test_count']:
            raise RuntimeError('Incomplete native default-playout tests')
        policy['report_sha256'] = sha(report)
    verify_files(source, MANIFEST['patched_files_sha256'])
    receipt = {**MANIFEST, 'platform': args.platform,
               'artifact': artifact.name if artifact else None,
               'artifact_sha256': sha(artifact) if artifact else None,
               'source_files_verified': True, 'shallow_checkout': True}
    if policy is not None:
        receipt['native_playout_policy_tests'] = policy
    (output / 'build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
