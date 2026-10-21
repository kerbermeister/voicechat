import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'package:voicechat_probe/call_window.dart';
import 'package:voicechat_probe/voice_call.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class CallRoom extends Room {
  CallRoom(Client client) : super(id: '!call:local', client: client);
  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock,
    ],
    bool suppressWarning = false,
    bool? cache,
    bool enforceFetchFromServer = false,
  ]) async => [];
}

class WindowCall implements VoiceCall {
  @override
  final Room chat;
  WindowCall(this.chat);
  @override
  String get session => 'window-test';
  @override
  String get connection => 'Защищённое видео';
  @override
  final bool video = true;
  @override
  bool cameraEnabled = true, muted = false, isClosed = false;
  @override
  VideoQuality videoQuality = VideoQuality.auto;
  @override
  CallQuality get quality => CallQuality.good;
  @override
  List<String> get participants => [];
  @override
  Duration get duration => const Duration(seconds: 42);
  @override
  Future<void> camera(bool enabled) async => cameraEnabled = enabled;
  @override
  Future<void> mute(bool value) async => muted = value;
  @override
  Future<void> switchCamera() async {}
  @override
  Future<void> setVideoQuality(VideoQuality value) async =>
      videoQuality = value;
  @override
  Future<void> close() async => isClosed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        (_) async => null,
      );
  testWidgets(
    'Video controls and quality stay usable on a narrow and rotated screen',
    (tester) async {
      final client = Client('window-test', database: OutboxDatabase());
      final call = WindowCall(CallRoom(client));
      final calls = CallController(
        client,
        'http://localhost:8090',
        'ws://localhost:7880',
        (_) {},
      )..active = call;
      for (final size in [const Size(320, 640), const Size(640, 320)]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            home: CallWindow(calls: calls, audioOutput: () async {}),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Хорошая связь'), findsOneWidget);
        await tester.tap(
          find.byTooltip(
            call.cameraEnabled ? 'Выключить камеру' : 'Включить камеру',
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final end = tester.getRect(find.text('Завершить'));
        expect(end.bottom, lessThanOrEqualTo(size.height));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(calls.close);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
