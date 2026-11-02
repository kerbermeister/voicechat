import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/stream_controller.dart';
import 'package:voicechat_probe/stream_panel.dart';
import 'package:voicechat_probe/stream_state.dart';
import 'package:voicechat_probe/stream_badge.dart';
import 'message_test.dart' show TestClient;
import 'stream_api_test.dart' show snapshot;

class StreamFixtureClient extends TestClient {
  @override
  String get deviceID => 'DEVICE';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'narrow setup validates title and duration before capture/network',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = LiveStreamController(
        StreamFixtureClient(),
        'http://127.0.0.1:8090',
        'ws://127.0.0.1:7880',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LiveStreamPanel(
            controller: controller,
            friends: const {'@friend:local'},
          ),
        ),
      );
      final start = find.widgetWithText(FilledButton, 'Начать стрим');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      expect(find.text('Введите название'), findsOneWidget);
      expect(controller.active, false);
      await tester.enterText(find.byType(TextFormField).first, 'test');
      await tester.enterText(find.byType(TextFormField).last, '181');
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pump();
      expect(find.text('Укажите время в пределах максимума'), findsOneWidget);
      expect(controller.active, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.snapshot = null; // The snapshot is a fixture, not a server session.
      final closing = controller.close();
      await tester.pump();
      await closing;
    },
  );
  testWidgets(
    'camera and microphone controls are independent and preserve session',
    (tester) async {
      final controller = LiveStreamController(
        StreamFixtureClient(),
        'http://127.0.0.1:8090',
        'ws://127.0.0.1:7880',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      controller.snapshot = LiveStreamSnapshot.parse({
        ...snapshot(),
        'owner': '@user:local',
        'owner_device': 'DEVICE',
      });
      controller.comments.add(
        const LiveStreamComment(1, '@friend:local', 'retained chat'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LiveStreamPanel(controller: controller, friends: const {}),
        ),
      );
      await tester.ensureVisible(find.byTooltip('Выключить камеру'));
      await tester.tap(find.byTooltip('Выключить камеру'));
      await tester.pump();
      expect(controller.cameraOn, false);
      expect(controller.microphoneOn, true);
      expect(controller.active, true);
      await tester.ensureVisible(find.byTooltip('Выключить микрофон'));
      await tester.tap(find.byTooltip('Выключить микрофон'));
      await tester.pump();
      expect(controller.microphoneOn, false);
      expect(controller.cameraOn, false);
      expect(controller.comments.single.text, 'retained chat');
      expect(controller.snapshot!.endsAt.millisecondsSinceEpoch, 1100000);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.snapshot = null; // The snapshot is a fixture, not a server session.
      final closing = controller.close();
      await tester.pump();
      await closing;
    },
  );
  testWidgets(
    'paused stream offers explicit continuation and accessible static badge',
    (tester) async {
      final controller = LiveStreamController(
        StreamFixtureClient(),
        'http://127.0.0.1:8090',
        'ws://127.0.0.1:7880',
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      controller.snapshot = LiveStreamSnapshot.parse({
        ...snapshot(),
        'owner': '@user:local',
        'owner_device': 'DEVICE',
        'state': 'paused',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LiveStreamPanel(controller: controller, friends: const {}),
        ),
      );
      expect(find.text('Продолжить стрим'), findsOneWidget);
      expect(find.text('Стрим на паузе'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: SizedBox(
                width: 48,
                height: 48,
                child: LiveStreamBadge(onTap: () {}),
              ),
            ),
          ),
        ),
      );
      expect(
        find.bySemanticsLabel('Идёт стрим. Информация и просмотр'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.snapshot = null; // The snapshot is a fixture, not a server session.
      final closing = controller.close();
      await tester.pump();
      await closing;
    },
  );
}
