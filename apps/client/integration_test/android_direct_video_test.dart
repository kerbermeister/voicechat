// Two real native WebRTC peers and emulated cameras; no accounts or server data.
// This checks the Android media pipeline, not Xiaomi hardware or Matrix delivery.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// ignore: depend_on_referenced_packages
import 'package:webrtc_interface/webrtc_interface.dart' as api;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:voicechat_probe/call_audio.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'package:voicechat_probe/call_quality.dart';
import '../test/chat_actions_test.dart' show OutboxDatabase;
import 'native_direct_call_test.dart' as fixture;

class WireSession extends fixture.LocalSession {
  WireSession(super.opts);
  @override
  String wireSdp(String sdp) {
    // Both peers share one plugin process. Wire IDs must differ from local IDs,
    // otherwise Android's global registry can bind the other peer's local camera.
    for (final track
        in localUserMediaStream?.stream?.getVideoTracks() ??
            <rtc.MediaStreamTrack>[]) {
      sdp = sdp.replaceAll(track.id!, 'wire-${track.id}');
    }
    return sdp;
  }
}

class CameraDevices extends Fake implements api.MediaDevices {
  CameraDevices(this.facing);
  final String facing;
  @override
  Future<rtc.MediaStream> getUserMedia(Map<String, dynamic> constraints) =>
      rtc.navigator.mediaDevices.getUserMedia({
        ...constraints,
        if (constraints['video'] is Map)
          'video': {...constraints['video'] as Map, 'facingMode': facing},
      });
}

class CameraDelegate extends fixture.NativeDelegate {
  CameraDelegate(String facing) : devices = CameraDevices(facing);
  final CameraDevices devices;
  @override
  get mediaDevices => devices;
}

class ProbeDatabase extends OutboxDatabase {
  @override
  Future<void> close() async {}
}

class MediaOnlyCall extends DirectCall {
  MediaOnlyCall(super.call, super.changed, super.report);
  // Identity/Matrix authorization is outside this isolated media transport probe.
  @override
  Future<void> authorize() async {}
}

Future<int> frames(DirectCall call) async =>
    (await call.receivedVideoStatistics()).fold<int>(
      0,
      (sum, stat) => sum + ((stat['framesDecoded'] as num?)?.toInt() ?? 0),
    );

Future<void> advancing(DirectCall call) async {
  final before = await frames(call);
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 30)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (await frames(call) > before + 5 &&
        (call.remoteVideo?.videoWidth ?? 0) > 0) {
      return;
    }
  }
  throw StateError('Video stopped: ${await call.receivedVideoStatistics()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android voice to video keeps rendering after renegotiation and transceiver refresh',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Synthetic Android media probe')),
        ),
      );
      final client = mx.Client(
        'isolated-android-video',
        database: ProbeDatabase(),
      );
      final audio = CallAudio();
      await audio.startDirectAudio();
      WireSession make(
        String name,
        mx.CallDirection direction,
        String facing,
      ) => WireSession(
        CallOptions(
          callId: 'isolated-video',
          type: mx.CallType.kVoice,
          dir: direction,
          localPartyId: name,
          voip: fixture.NativeVoip(name, delegate: CameraDelegate(facing)),
          room: mx.Room(client: client, id: '!isolated:local'),
          iceServers: [],
        ),
      );
      final caller = make('caller', mx.CallDirection.kOutgoing, 'user');
      final callee = make('callee', mx.CallDirection.kIncoming, 'environment');
      caller.peer = callee;
      callee.peer = caller;
      caller.remoteUserId = '@callee:local';
      callee.remoteUserId = '@caller:local';
      final local = MediaOnlyCall(caller, () {}, debugPrint);
      final remote = MediaOnlyCall(callee, () {}, debugPrint);
      try {
        await caller.initOutboundCall(mx.CallType.kVoice);
        await caller.invited.future.timeout(const Duration(seconds: 30));
        await callee.answer();
        await fixture.until(
          () =>
              caller.state == mx.CallState.kConnected &&
              callee.state == mx.CallState.kConnected,
        );
        await local.camera(true);
        await advancing(remote);
        // Exercise the SDK's explicit track binding as used by native track renderers.
        expect(
          callee.remoteUserMediaStream!.stream!.getVideoTracks().single.id,
          isNot(
            caller.localUserMediaStream!.stream!.getVideoTracks().single.id,
          ),
        );
        await remote.remoteVideo!.setSrcObject(
          stream: callee.remoteUserMediaStream!.stream,
          trackId: callee.remoteUserMediaStream!.stream!
              .getVideoTracks()
              .single
              .id,
        );
        for (var sample = 0; sample < 4; sample++) {
          await advancing(remote);
          debugPrint(
            'VIDEO_PROBE $sample: local=${await local.receivedVideoStatistics()}; remote=${await remote.receivedVideoStatistics()}',
          );
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        // Decoding alone misses a detached renderer sink (upstream #2230).
        expect(remote.remoteVideo!.videoWidth, greaterThan(320));
        await callee.pc!.getTransceivers();
        await callee.pc!.getTransceivers();
        await local.setVideoQuality(VideoQuality.low);
        await advancing(remote);
        debugPrint(
          'VIDEO_RENDER_COMPARISON: renderer=${remote.remoteVideo!.videoWidth}x${remote.remoteVideo!.videoHeight}; decoded=${await remote.receivedVideoStatistics()}',
        );
        await fixture.until(
          () =>
              remote.remoteVideo!.videoWidth <= 320 &&
              remote.remoteVideo!.videoHeight <= 180,
        );
        debugPrint(
          'VIDEO_RENDER_AFTER_TRANSCEIVERS: ${remote.remoteVideo!.videoWidth}x${remote.remoteVideo!.videoHeight}',
        );
        await local.setVideoQuality(VideoQuality.auto);
        await advancing(remote);
        for (var cycle = 0; cycle < 2; cycle++) {
          await local.camera(false);
          await Future<void>.delayed(const Duration(seconds: 1));
          await local.camera(true);
          await advancing(remote);
          debugPrint(
            'VIDEO_REPLACEMENT $cycle: ${await remote.receivedVideoStatistics()}',
          );
        }
        final codecs =
            (await rtc.getRtpSenderCapabilities('video')).codecs ?? [];
        final h264 = codecs
            .where((codec) => codec.mimeType.toLowerCase() == 'video/h264')
            .toList();
        if (h264.isNotEmpty) {
          for (final peer in [caller.pc!, callee.pc!]) {
            for (final transceiver in await peer.getTransceivers()) {
              if (transceiver.sender.track?.kind == 'video') {
                await transceiver.setCodecPreferences(h264);
              }
            }
          }
          await caller.onNegotiationNeeded();
          await advancing(remote);
          expect(
            (await remote.receivedVideoStatistics()).any(
              (stat) => stat['codec'] == 'video/H264',
            ),
            true,
          );
          debugPrint('VIDEO_H264: ${await remote.receivedVideoStatistics()}');
        } else {
          debugPrint(
            'VIDEO_H264_UNAVAILABLE: emulator does not advertise an H264 encoder',
          );
        }
      } finally {
        await Future.wait([local.close(), remote.close()]);
        await audio.stopDirectAudio();
        await client.dispose();
      }
    },
    skip:
        !Platform.isAndroid ||
        !const bool.fromEnvironment('ANDROID_VIDEO_PROBE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
