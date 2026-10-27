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
}
