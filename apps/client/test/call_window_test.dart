import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/call_quality.dart';
import 'package:voicechat_probe/call_window.dart';
import 'package:voicechat_probe/voice_call.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class WindowDatabase extends OutboxDatabase {
  @override
  Future<void> close() async {}
}

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
  WindowCall(this.chat, {this.video = true});
  @override
  String get session => 'window-test';
  @override
  String get connection => 'Защищённое видео';
  @override
  final bool video;
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
      final client = Client('window-test', database: WindowDatabase());
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
            theme: AppPalette.lavender.theme,
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
  testWidgets('Voice call keeps avatar, name, time and real signal visible', (
    tester,
  ) async {
    final client = Client('voice-window', database: WindowDatabase());
    final room = CallRoom(client);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        '@peer:example.org': [room.id],
      },
    );
    room.states[EventTypes.RoomMember] = {
      '@peer:example.org': StrippedStateEvent(
        type: EventTypes.RoomMember,
        stateKey: '@peer:example.org',
        senderId: '@peer:example.org',
        content: {'membership': 'join', 'displayname': 'Александра'},
      ),
    };
    room.states[EventTypes.RoomName] = {
      '': StrippedStateEvent(
        type: EventTypes.RoomName,
        stateKey: '',
        senderId: '@peer:example.org',
        content: {
          'name': 'voicechat contact 12345678-1234-1234-1234-123456789012',
        },
      ),
    };
    final calls = CallController(
      client,
      'http://localhost:8090',
      'ws://localhost:7880',
      (_) {},
    )..active = WindowCall(room, video: false);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(320, 640), const Size(1440, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.lavender.theme,
          home: Scaffold(
            body: CallWindow(calls: calls, audioOutput: () async {}),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Александра'), findsOneWidget);
      expect(find.textContaining('voicechat contact'), findsNothing);
      expect(find.text('0:42'), findsOneWidget);
      expect(find.byType(CallAvatar), findsOneWidget);
      expect(find.byType(CallQualityIndicator), findsOneWidget);
      expect(
        tester.getCenter(find.text('Александра')).dx,
        closeTo(size.width / 2, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    calls.active = null;
    await tester.runAsync(calls.close);
    await client.dispose();
  });
}
