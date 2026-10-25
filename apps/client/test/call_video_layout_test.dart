import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/call_video_grid.dart';

void main() {
  testWidgets('Peer fills the stage; hiding preview preserves the peer', (
    tester,
  ) async {
    final remoteKey = GlobalKey();
    final localKey = GlobalKey();
    for (final size in [const Size(320, 640), const Size(640, 320)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CallVideoLayout(
              local: ColoredBox(key: localKey, color: Colors.blue),
              remote: [ColoredBox(key: remoteKey, color: Colors.red)],
            ),
          ),
        ),
      );
      await tester.pump();
      final peer = tester.element(find.byKey(remoteKey));
      expect(tester.getSize(find.byKey(remoteKey)), size);
      expect(
        tester.getSize(find.byKey(localKey)).width,
        lessThanOrEqualTo(112),
      );
      await tester.tap(find.byTooltip('Скрыть своё видео'));
      await tester.pump();
      expect(find.byKey(localKey), findsNothing);
      expect(tester.element(find.byKey(remoteKey)), same(peer));
      await tester.tap(find.byTooltip('Показать своё видео'));
      await tester.pump();
      expect(find.byKey(localKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
