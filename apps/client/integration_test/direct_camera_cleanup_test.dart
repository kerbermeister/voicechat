// Opt-in real camera check. No Matrix server, account, profile, audio or media transport.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
import '../test/chat_actions_test.dart'
    show VideoSession, OutboxRoom, OutboxDatabase;
import '../test/direct_call_media_test.dart'
    show CameraPeer, AuthorizedCameraCall;

class NativeFeed implements mx.WrappedMediaStream {
  NativeFeed(this.stream);
  @override
  final rtc.MediaStream stream;
  @override
  bool videoMuted = true;
  @override
  bool isLocal() => true;
  @override
  void setVideoMuted(bool muted) {
    videoMuted = muted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NativeCameraSession extends VideoSession {
  NativeCameraSession(this.feed)
    : room = OutboxRoom(
        mx.Client('disposable-native-camera-check', database: OutboxDatabase()),
      );
  final NativeFeed feed;
  @override
  final mx.Room room;
  final CameraPeer peer = CameraPeer();
  @override
  CameraPeer get pc => peer;
  bool cleared = false, failMute = false;
  mx.CallState current = mx.CallState.kRinging;
  @override
  mx.CallState get state => current;
  @override
  mx.CallType get type => mx.CallType.kVoice;
  @override
  mx.WrappedMediaStream? get localUserMediaStream => cleared ? null : feed;
  @override
  List<mx.WrappedMediaStream> get getLocalStreams => cleared ? [] : [feed];
  @override
  bool get isLocalVideoMuted => feed.videoMuted;
  @override
  Future<void> updateMuteStatus() async {
    if (failMute) throw StateError('deliberate signalling outage');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'macOS real camera stops during ringing, timeout and late sender completion',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text('Изолированная проверка освобождения камеры'),
            ),
          ),
        ),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // Observe calls but forward every one to the real native plugin, including capture/stop.
      const codec = StandardMethodCodec();
      final native = MethodChannel(
        'FlutterWebRTC.Method',
        codec,
        messenger.delegate,
      );
      final lifecycle = <MethodCall>[];
      String? sourceId;
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (method) async {
          lifecycle.add(method);
          final result = await native.invokeMethod<dynamic>(
            method.method,
            method.arguments,
          );
          if (method.method == 'getUserMedia') {
            sourceId = (result as Map)['streamId'] as String;
          }
          return result;
        },
      );
      try {
        for (final stage in [
          'off-with-signalling-error',
          'timeout',
          'late-sender',
        ]) {
          sourceId = null;
          lifecycle.clear();
          final stream = await rtc.createLocalMediaStream(
            'camera-cleanup-$stage',
          );
          final session = NativeCameraSession(NativeFeed(stream));
          final reports = <String>[];
          final call = AuthorizedCameraCall(session, () {}, reports.add);
          try {
            if (stage == 'late-sender') {
              session.pc.gate = Completer<rtc.RTCRtpSender>();
            }
            final enabling = call.camera(true);
            if (stage == 'late-sender') {
              await session.pc.attached.future.timeout(
                const Duration(seconds: 30),
              );
            } else {
              await enabling.timeout(const Duration(seconds: 30));
            }
            expect(sourceId, isNotNull);
            final sourceTracks = await native.invokeMapMethod<String, dynamic>(
              'mediaStreamGetTracks',
              {'streamId': sourceId},
            );
            expect(
              sourceTracks!['videoTracks'],
              isNotEmpty,
              reason: 'Source must remain owned while camera is active',
            );
            await tester.pump(const Duration(milliseconds: 300));
            if (stage == 'off-with-signalling-error') {
              session.failMute = true;
              await call.camera(false);
              expect(reports, contains(contains('Камера выключена')));
              final stoppedTracks = await native
                  .invokeMapMethod<String, dynamic>('mediaStreamGetTracks', {
                    'streamId': stream.id,
                  });
              expect(stoppedTracks?['videoTracks'] ?? [], isEmpty);
            } else {
              // Reproduce the SDK losing its feed while our newly acquired camera still exists.
              session.cleared = true;
              await stream.dispose();
              session.current = mx.CallState.kEnded;
              await call.close();
              if (stage == 'late-sender') {
                session.pc.gate!.complete(session.pc.sender);
                await expectLater(enabling, throwsStateError);
              }
            }
            expect(call.cameraEnabled, false);
            final stop = lifecycle.indexWhere(
              (method) => method.method == 'trackDispose',
            );
            final release = lifecycle.indexWhere(
              (method) =>
                  method.method == 'streamDispose' &&
                  (method.arguments as Map)['streamId'] == sourceId,
            );
            expect(stop, greaterThanOrEqualTo(0));
            expect(release, greaterThan(stop));
            final remaining = await native.invokeMapMethod<String, dynamic>(
              'mediaStreamGetTracks',
              {'streamId': sourceId},
            );
            expect(remaining?['videoTracks'] ?? [], isEmpty);
            debugPrint('PASS: native camera capture released — $stage');
          } finally {
            await call.close();
            await stream.dispose();
          }
        }
      } finally {
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          null,
        );
      }
    },
    skip:
        !Platform.isMacOS ||
        !const bool.fromEnvironment('HARDWARE_CAMERA_TEST'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
