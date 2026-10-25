import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/device_verification.dart';
import 'package:voicechat_probe/device_verification_dialog.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'device_verification_test.dart' show Proof;
import 'first_keys_test.dart' show PinDevice;
import 'test_fonts.dart';

void main() {
  void expectVisible(Rect rect, Rect viewport) {
    expect(rect.left, greaterThanOrEqualTo(viewport.left - 0.1));
    expect(rect.top, greaterThanOrEqualTo(viewport.top - 0.1));
    expect(rect.right, lessThanOrEqualTo(viewport.right + 0.1));
    expect(rect.bottom, lessThanOrEqualTo(viewport.bottom + 0.1));
  }

  for (final (size, scale) in [
    (const Size(320, 568), 1.0),
    (const Size(390, 600), 1.0),
    (const Size(320, 568), 1.5),
  ]) {
    testWidgets('SAS is visible without scrolling at $size, text $scale', (
      tester,
    ) async {
      await loadAppFont();
      const capture = bool.fromEnvironment('CAPTURE_VERIFICATION_LAYOUT');
      const captureKey = ValueKey('verification-capture');
      if (capture) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(
                ByteData.sublistView(
                  materialFontFile(
                    'MaterialIcons-Regular.otf',
                  ).readAsBytesSync(),
                ),
              ),
            ))
            .load();
        await (FontLoader('monospace')..addFont(
              Future.value(
                ByteData.sublistView(
                  materialFontFile('Roboto-Regular.ttf').readAsBytesSync(),
                ),
              ),
            ))
            .load();
      }
      Future<void> captureStage(String stage) async {
        if (!capture) return;
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(captureKey))
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/voicechat-verification-${size.width.toInt()}-$scale-$stage.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final owner = DeviceVerifications(
        Client('sas-layout', database: OutboxDatabase()),
        () {},
      );
      final proof = Proof(
        PinDevice('@mobile-user:univc.duckdns.org', 'ABCDEFGHIJ', 'key'),
      )..state = KeyVerificationState.askAccept;
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppPalette.halo.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showDeviceVerification(context, owner, proof),
                  child: const Text('Start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      proof.state = KeyVerificationState.askSas;
      // Incoming protocol progress must reveal SAS without manually scrolling.
      owner.notifyListeners();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final emoji in proof.sasEmojis.take(6)) {
          await precacheImage(
            AssetImage(
              'assets/verification/emoji_u${emoji.emoji.runes.first.toRadixString(16)}.png',
            ),
            tester.element(find.byType(AlertDialog)),
          );
        }
      });
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      final images = find.byType(Image);
      expect(images, findsNWidgets(6));
      for (final raw in tester.widgetList<RawImage>(find.byType(RawImage))) {
        expect(raw.image, isNotNull);
      }
      final first = tester.getRect(images.first);
      for (var i = 0; i < 6; i++) {
        final rect = tester.getRect(images.at(i));
        expectVisible(rect, viewport);
        expect(rect.center.dy, closeTo(first.center.dy, 1));
        expect(rect.width, greaterThanOrEqualTo(30));
      }
      final reject = tester.getRect(find.text('Не совпадают'));
      final accept = tester.getRect(find.text('Совпадают'));
      if (scale == 1) expect(reject.center.dy, closeTo(accept.center.dy, 1));
      expect(
        tester.getSize(find.byType(OutlinedButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(find.text('Не совпадают').hitTestable(), findsOneWidget);
      expect(find.text('Совпадают').hitTestable(), findsOneWidget);
      await captureStage('emoji');
      await tester.tap(find.text('Код'));
      await tester.pumpAndSettle();
      final code = tester.getRect(find.text('1234  5678  9012'));
      final codeViewport = tester.getRect(find.byType(SingleChildScrollView));
      expectVisible(code, codeViewport);
      await captureStage('code');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(proof.canceled, isTrue);
      await tester.runAsync(owner.close);
    });
  }
}
