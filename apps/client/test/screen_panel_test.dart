import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/screen_api.dart';
import 'package:voicechat_probe/screen_controller.dart';
import 'package:voicechat_probe/screen_panel.dart';
import 'package:voicechat_probe/screen_state.dart';
import 'package:voicechat_probe/voice_call.dart';
import 'screen_protocol_test.dart' show active;

class PanelDatabase extends Fake implements DatabaseApi {
  @override
  Future<void> close() async {}
}

class PanelCall extends Fake implements VoiceCall {
  @override
  final Room chat;
  PanelCall(this.chat);
  @override
  bool get isClosed => false;
}

void main() {
  testWidgets(
    'Экран остаётся отдельным, fullscreen закрывает только просмотр',
    (tester) async {
      final client = Client('screen-panel', database: PanelDatabase());
      final call = PanelCall(Room(id: '!screen:local', client: client));
      final controller =
          ScreenShareController(
              call,
              ScreenApi('http://localhost', () => ''),
              'ws://localhost:7880',
            )
            ..snapshot = ScreenSnapshot.parse(active())
            ..phase = ScreenPhase.viewing;
      for (final size in [const Size(320, 640), const Size(640, 320)]) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ScreenPanel(controller: controller),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('Перехватить экран'), findsOneWidget);
        expect(find.byType(Semantics), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Развернуть экран'));
        await tester.tap(find.byTooltip('Развернуть экран'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Вернуться в звонок'), findsOneWidget);
        await tester.tap(find.byTooltip('Вернуться в звонок'));
        await tester.pumpAndSettle();
        expect(controller.isClosed, isFalse);
        expect(find.text('Перехватить экран'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.close();
      controller.dispose();
      await client.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
