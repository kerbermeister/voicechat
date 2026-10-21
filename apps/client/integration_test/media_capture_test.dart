import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voicechat_probe/video_note.dart';
import 'package:voicechat_probe/picked_file.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android camera switch, timed circular recording and bounded read',
    (tester) async {
      ({PickedFile file, int duration})? recorded;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  recorded = await recordVideoNote(context, 2);
                },
                child: const Text('Камера'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Камера'));
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 30 &&
            !tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Записать'),
                )
                .enabled;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pump();
      }
      final switcher = find.byTooltip('Переключить камеру');
      if (switcher.evaluate().isNotEmpty) {
        await tester.tap(switcher);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 1)),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Записать'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 4)),
      );
      await tester.pumpAndSettle();
      expect(recorded, isNotNull);
      expect(recorded!.duration, inInclusiveRange(1, 2000));
      expect(recorded!.file.mime, startsWith('video/'));
      expect(recorded!.file.size, greaterThan(32));
      final first = await recorded!.file.read(0, 32);
      expect(first.length, 32);
      await recorded!.file.release();
    },
  );
}
