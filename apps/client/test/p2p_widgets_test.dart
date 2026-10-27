import 'dart:typed_data';
import 'package:voicechat_probe/file_drop.dart';
import 'package:voicechat_probe/picked_file.dart';
import 'package:voicechat_probe/p2p/service.dart';
import 'p2p_service_test.dart' show P2pClient, Friends;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/p2p/panel.dart';
import 'package:voicechat_probe/p2p/flow.dart';
import 'package:voicechat_probe/p2p/protocol.dart';

void main() {
  testWidgets(
    'flow becomes static with reduced motion and settles when traffic stops',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: P2pFlow(moving: true, complete: false, outgoing: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      expect(find.text('Получатель'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: P2pFlow(moving: false, complete: true, outgoing: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    },
  );
  testWidgets(
    'relay warning is persistent, wraps on narrow screen and route is truthful',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: P2pRouteWarning(route: P2pRoute.relay, outgoing: true),
          ),
        ),
      );
      expect(
        find.textContaining('Файлы передаются через сервер-ретранслятор'),
        findsOneWidget,
      );
      await tester.pump(const Duration(minutes: 1));
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: P2pRouteWarning(route: P2pRoute.unknown, outgoing: true),
          ),
        ),
      );
      expect(find.text('Напрямую'), findsNothing);
      expect(find.text('Определяем маршрут'), findsOneWidget);
    },
  );
  testWidgets('file ring and precise progress support reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: P2pFileProgress(
              file: P2pFile('test', 'a', 5000000000, ''),
              bytes: 1871000000,
              verified: false,
            ),
          ),
        ),
      ),
    );
    expect(find.text('37,42%'), findsOneWidget);
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, closeTo(.3742, .00001));
  });
  testWidgets(
    'draft stays local until explicit send, then cancel releases its source',
    (tester) async {
      final client = P2pClient();
      final friends = Friends(client);
      final service = P2pService(client, friends, 'https://local.invalid');
      var released = 0;
      await tester.pumpWidget(MaterialApp(home: P2pPanel(service: service)));
      await tester.pumpAndSettle();
      tester.widget<FileDrop>(find.byType(FileDrop)).onDrop([
        PickedFile(
          name: 'empty.txt',
          mime: 'text/plain',
          size: 0,
          read: (_, __) async => Uint8List(0),
          release: () async {
            released++;
          },
        ),
      ]);
      await tester.pumpAndSettle();
      expect(client.sent, isEmpty);
      await tester.tap(find.text('Друзья (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      expect(client.sent, isEmpty);
      await tester.ensureVisible(find.text('Отправить'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Отправить'));
        for (var i = 0; i < 100 && service.preparing; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(client.sent.where((e) => e['op'] == 'offer'), hasLength(1));
      expect(service.transfers.single.bytes, [0]);
      expect(service.transfers.single.wire, isNull);
      expect(released, 0);
      await tester.ensureVisible(find.text('Отменить передачу'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отменить передачу'));
      await tester.pumpAndSettle();
      expect(service.transfers.single.state, P2pState.cancelled);
      expect(released, 1);
      await tester.pumpWidget(const SizedBox());
      await service.close();
      await friends.close();
      await client.onToDeviceEvent.close();
    },
  );
}
