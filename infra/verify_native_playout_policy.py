"""Execute the native SDK's default-playout configuration, without media devices."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

DEFAULT = 'WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:10000/'
CASES = [
    ('', DEFAULT),
    ('WebRTC-ForcePlayoutDelay/min_ms:130,max_ms:130/', 'WebRTC-ForcePlayoutDelay/min_ms:130,max_ms:130/'),
    ('WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:0/', 'WebRTC-ForcePlayoutDelay/min_ms:0,max_ms:0/'),
    ('WebRTC-IceHandshakeDtls/Enabled/', 'WebRTC-IceHandshakeDtls/Enabled/' + DEFAULT),
    ('Other/WebRTC-ForcePlayoutDelay/', 'Other/WebRTC-ForcePlayoutDelay/' + DEFAULT),
    ('Other/Enabled', 'Other/Enabled'),
    ('Other//', 'Other//'),
    ('WebRTC-ForcePlayoutDelay/min_ms:90,max_ms:90/', 'WebRTC-ForcePlayoutDelay/min_ms:90,max_ms:90/'),
    ('WebRTC-ForcePlayoutDelay/min_ms:90,max_ms:10000/', 'WebRTC-ForcePlayoutDelay/min_ms:90,max_ms:10000/'),
    (None, None),
]


def block(source, signature):
    start = source.index(signature)
    first = source.index('{', start)
    depth = 1
    for end in range(first + 1, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1], source[first + 1:end]
    raise ValueError('Unterminated configuration function')


def invoke(args, cwd):
    result = subprocess.run(list(map(str, args)), cwd=cwd, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} exited {result.returncode}: ' + result.stdout + result.stderr)


def verify_macos_receivers(work, framework_dir):
    test = work / 'video-receiver.m'
    test.write_text('''#import <WebRTC/WebRTC.h>

int main(void) {
  @autoreleasepool {
    RTCPeerConnectionFactory *factory = [[RTCPeerConnectionFactory alloc] init];
    RTCConfiguration *configuration = [[RTCConfiguration alloc] init];
    configuration.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
    RTCMediaConstraints *constraints =
        [[RTCMediaConstraints alloc] initWithMandatoryConstraints:nil
                                              optionalConstraints:nil];
    RTCPeerConnection *peer = [factory peerConnectionWithConfiguration:configuration
                                                          constraints:constraints
                                                             delegate:nil];
    RTCRtpReceiver *video = [peer addTransceiverOfType:RTCRtpMediaTypeVideo].receiver;
    RTCRtpReceiver *audio = [peer addTransceiverOfType:RTCRtpMediaTypeAudio].receiver;
    int result = 0;
    if (!video || !audio || ![video setMinimumVideoPlayoutDelayMs:70] ||
        ![video setMinimumVideoPlayoutDelayMs:0] ||
        [video setMinimumVideoPlayoutDelayMs:-1] ||
        [video setMinimumVideoPlayoutDelayMs:10001] ||
        [audio setMinimumVideoPlayoutDelayMs:70] ||
        ![audio setMinimumAudioPlayoutDelayMs:40] ||
        ![audio setMinimumAudioPlayoutDelayMs:0] ||
        [audio setMinimumAudioPlayoutDelayMs:-1] ||
        [audio setMinimumAudioPlayoutDelayMs:10001] ||
        [video setMinimumAudioPlayoutDelayMs:40]) {
      result = 1;
    }
    [peer close];
    return result;
  }
}
''')
    executable = work / 'video-receiver'
    invoke(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=12.0',
            '-F', framework_dir, '-rpath', framework_dir,
            '-framework', 'Foundation', '-framework', 'WebRTC',
            test, '-o', executable], work)
    invoke([executable], work)


def verify(source, platform, output, artifact=None, binary=None):
    with tempfile.TemporaryDirectory(prefix='webrtc-playout-policy-') as temporary:
        work = Path(temporary)
        if platform == 'android':
            if artifact is None:
                raise ValueError('Android policy verification needs the actual AAR')
            with zipfile.ZipFile(artifact) as archive:
                classes = archive.read('classes.jar')
            (work / 'classes.jar').write_bytes(classes)
            context = work / 'android/content/Context.java'
            context.parent.mkdir(parents=True)
            context.write_text('package android.content; public class Context {}\n')
            checks = []
            for index, (value, expected) in enumerate(CASES):
                checks.append(f'''check({index}, {json.dumps(value)}, {json.dumps(expected)});''')
            # Same package: inspect the real InitializationOptions built by the AAR.
            # Context is an inert type only; no Android API or native library runs.
            test = work / 'org/webrtc/PlayoutPolicyCheck.java'
            test.parent.mkdir(parents=True)
            test.write_text('''package org.webrtc;
import android.content.Context;
import java.util.Objects;
public class PlayoutPolicyCheck {
  static void check(int index, String input, String expected) {
    PeerConnectionFactory.InitializationOptions value =
        PeerConnectionFactory.InitializationOptions.builder(new Context())
            .setFieldTrials(input).createInitializationOptions();
    if (!Objects.equals(value.fieldTrials, expected)) {
      throw new AssertionError("case " + index + ": " + value.fieldTrials);
    }
  }
  public static void main(String[] args) {
''' + '\n'.join(checks) + '\n  }\n}\n')
            # The AAR is compiled by Chromium's pinned JDK, which can be newer
            # than the runner's default. Use that same JDK to execute its API.
            javac = source / 'third_party/jdk/current/bin/javac'
            if not javac.is_file():
                installed = shutil.which('javac')
                if installed is None:
                    raise RuntimeError('Android policy verification needs a JDK')
                javac = Path(installed).resolve()
            java = javac.with_name('java')
            invoke([javac, '-cp', work / 'classes.jar', '-d', work, context, test], work)
            invoke([java, '-cp', str(work) + ':' + str(work / 'classes.jar'),
                    'org.webrtc.PlayoutPolicyCheck'], work)
            identity = {'classes_sha256': hashlib.sha256(classes).hexdigest()}
        elif platform == 'macos':
            path = source / 'sdk/objc/api/peerconnection/RTCPeerConnectionFactory.mm'
            native = path.read_text()
            signature = 'static NSString *FieldTrialsWithDefaultVideoPlayout('
            helper = block(native, signature)[0] if signature in native else ''
            _, body = block(native, '+ (void)configureFieldTrials:')
            checks = []
            for index, (value, expected) in enumerate(CASES):
                value = 'nil' if value is None else '@' + json.dumps(value)
                expected = '@' + json.dumps(DEFAULT if expected is None else expected)
                checks.append(f'if (![configure({value}) isEqualToString:{expected}]) return {index + 1};')
            test = work / 'policy.mm'
            test.write_text('#import <Foundation/Foundation.h>\n' + helper + '''
static NSString *configure(NSString *fieldTrials) {
  NSString *gFieldTrials;
''' + body + '\n  return gFieldTrials;\n}\nint main() { @autoreleasepool {\n' + '\n'.join(checks) + '\n} return 0; }\n')
            invoke(['xcrun', 'clang++', '-fobjc-arc', '-mmacosx-version-min=12.0',
                    '-framework', 'Foundation', test, '-o', work / 'policy'], work)
            invoke([work / 'policy'], work)
            if binary is not None and DEFAULT.encode() not in binary.read_bytes():
                raise ValueError('Compiled macOS SDK lacks the tested default policy')
            identity = {'configuration_source_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                        'compiled_binary_checked': binary is not None}
            if binary is not None:
                verify_macos_receivers(work, binary.parent.parent.resolve())
                identity['compiled_video_receiver_checked'] = True
                identity['compiled_audio_receiver_checked'] = True
        else:
            raise ValueError('Unknown native platform')
    report = {'platform': platform, 'test_count': len(CASES), 'pass_count': len(CASES),
              'outcome': 'pass', 'configuration_only': True, **identity}
    output.write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos', 'android'])
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--binary', type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.source, args.platform, args.output, args.artifact, args.binary)))


if __name__ == '__main__':
    main()
