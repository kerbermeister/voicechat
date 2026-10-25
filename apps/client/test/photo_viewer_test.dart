import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:voicechat_probe/photo_viewer.dart';
import 'package:voicechat_probe/theme.dart';

void main() {
  testWidgets(
    'Photo controls remain clear, navigate both ways, preserve zoom and close from the upper right',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final bytes = img.encodePng(img.Image(width: 100, height: 80));
      for (final size in [const Size(320, 568), const Size(1366, 768)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.halo.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: size.width == 320),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showPhotos(context, [
                    () async => bytes,
                    () async => bytes,
                    () async => bytes,
                  ], 1),
                  child: const Text('Фото'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Фото'));
        await tester.pumpAndSettle();
        final close = find.byTooltip('Закрыть просмотр');
        final rect = tester.getRect(close);
        expect(rect.right, closeTo(size.width - 12, .5));
        expect(rect.top, closeTo(12, .5));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(find.byType(InteractiveViewer), findsWidgets);
        expect(find.text('2 / 3'), findsOneWidget);
        await tester.tap(find.byTooltip('Следующее фото'));
        await tester.pumpAndSettle();
        expect(find.text('3 / 3'), findsOneWidget);
        expect(find.byTooltip('Следующее фото'), findsNothing);
        await tester.tap(find.byTooltip('Предыдущее фото'));
        await tester.pumpAndSettle();
        expect(find.text('2 / 3'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        expect(find.text('1 / 3'), findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(PhotoViewer), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'Single photo has no paging actions and Escape closes the viewer',
    (tester) async {
      final bytes = img.encodePng(img.Image(width: 10, height: 10));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPhotos(context, [() async => bytes], 0),
                child: const Text('Фото'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Фото'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Предыдущее фото'), findsNothing);
      expect(find.byTooltip('Следующее фото'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
