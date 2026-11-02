// Real Mac camera and two native WebRTC peers; synthetic in-memory signaling.
// No Matrix authorization, TURN or second physical device is claimed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:voicechat_probe/call_quality.dart';

import '../../../apps/client/integration_test/native_direct_call_test.dart'
    as fixture;
import '../../../apps/client/integration_test/android_direct_video_test.dart'
    as video;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Native Mac audio to video, low quality, two camera restarts and remote hangup',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('QA local video transport')),
        ),
      );
      final client = mx.Client('qa-mac-video', database: video.ProbeDatabase());
      video.WireSession make(String name, mx.CallDirection direction) =>
          video.WireSession(
            CallOptions(
              callId: 'qa-local-video',
              type: mx.CallType.kVoice,
              dir: direction,
              localPartyId: name,
              voip: fixture.NativeVoip(name),
              room: mx.Room(client: client, id: '!qa-video:local'),
              iceServers: [],
            ),
          );
      final a = make('qa-a', mx.CallDirection.kOutgoing),
          b = make('qa-b', mx.CallDirection.kIncoming);
      a.peer = b;
      b.peer = a;
      a.remoteUserId = '@qa-b:local';
      b.remoteUserId = '@qa-a:local';
      final local = video.MediaOnlyCall(a, () {}, (_) {}),
          remote = video.MediaOnlyCall(b, () {}, (_) {});
      final subscriptions = [a, b]
          .map(
            (s) => s.onStreamAdd.stream.listen((stream) {
              if (!stream.isLocal()) {
                for (final t in stream.stream!.getAudioTracks()) {
                  t.enabled = false;
                }
              }
            }),
          )
          .toList();
      try {
        await a.initOutboundCall(mx.CallType.kVoice);
        await a.invited.future.timeout(const Duration(seconds: 20));
        await b.answer();
        await fixture.until(
          () =>
              a.state == mx.CallState.kConnected &&
              b.state == mx.CallState.kConnected,
        );
        await local.camera(true);
        await video.advancing(remote);
        expect(remote.remoteVideo!.videoWidth, greaterThan(0));
        debugPrint('QA_VIDEO initial frames and renderer PASS');
        await local.setVideoQuality(VideoQuality.low);
        await video.advancing(remote);
        await fixture.until(
          () =>
              remote.remoteVideo!.videoWidth <= 320 &&
              remote.remoteVideo!.videoHeight <= 180,
        );
        debugPrint(
          'QA_VIDEO low ${remote.remoteVideo!.videoWidth}x${remote.remoteVideo!.videoHeight} PASS',
        );
        for (var cycle = 0; cycle < 2; cycle++) {
          await local.camera(false);
          expect(local.cameraEnabled, false);
          expect(a.localUserMediaStream!.stream!.getVideoTracks(), isEmpty);
          await local.camera(true);
          await video.advancing(remote);
          debugPrint(
            'QA_VIDEO restart $cycle decoded frames and renderer PASS',
          );
        }
        await local.close();
        await fixture.until(() => remote.isClosed);
        expect(local.cameraEnabled, false);
        debugPrint('QA_VIDEO remote hangup and local camera stopped PASS');
      } finally {
        await Future.wait([local.close(), remote.close()]);
        for (final s in subscriptions) {
          await s.cancel();
        }
        await client.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
