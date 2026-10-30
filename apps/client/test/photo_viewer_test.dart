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
  testWidgets(
    'Invisible side zones navigate at top and bottom while arrows and zoom gestures remain available',
    (tester) async {
      final bytes = img.encodePng(img.Image(width: 100, height: 80));
      for (final size in [const Size(320, 640), const Size(1000, 800)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PhotoViewer(
                key: ValueKey(size),
                photos: List.generate(
                  3,
                  (_) =>
                      () async => bytes,
                ),
                initial: 1,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final surface = tester.getRect(
          find.byKey(const ValueKey('photo-navigation-surface')),
        );
        expect(surface.height, size.height);
        expect(
          tester.getSize(find.byTooltip('Следующее фото')),
          const Size(56, 56),
        );
        await tester.tapAt(Offset(surface.right - 20, surface.top + 100));
        await tester.pumpAndSettle();
        expect(find.text('3 / 3'), findsOneWidget);
        await tester.tapAt(Offset(surface.left + 20, surface.bottom - 30));
        await tester.pumpAndSettle();
        expect(find.text('2 / 3'), findsOneWidget);
        await tester.tapAt(Offset(surface.left + 20, surface.top + 100));
        await tester.pumpAndSettle();
        expect(find.text('1 / 3'), findsOneWidget);
        await tester.tapAt(Offset(surface.right - 20, surface.bottom - 30));
        await tester.pumpAndSettle();
        expect(find.text('2 / 3'), findsOneWidget);
        final first = await tester.startGesture(
          surface.center - const Offset(25, 0),
          pointer: 1,
        );
        final second = await tester.startGesture(
          surface.center + const Offset(25, 0),
          pointer: 2,
        );
        await tester.pump();
        await first.moveBy(const Offset(-30, 0));
        await second.moveBy(const Offset(30, 0));
        await tester.pump();
        await first.up();
        await second.up();
        await tester.pumpAndSettle();
        expect(
          find.text('2 / 3'),
          findsOneWidget,
          reason: 'Pinch must not trigger a side tap',
        );
        expect(find.byType(InteractiveViewer), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
      await tester.binding.setSurfaceSize(null);
    },
  );
}
