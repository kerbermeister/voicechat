import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/active_call_banner.dart';
import 'package:voicechat_probe/copy_feedback.dart';
import 'package:voicechat_probe/clipboard_file.dart';
import 'package:voicechat_probe/media_clipboard_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Clipboard commits exact bytes; truncated or oversized streams cancel',
    () async {
      final operations = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('voicechat/clipboard'),
        (call) async {
          operations.add(call);
          return call.method == 'begin' ? 'transfer' : null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('voicechat/clipboard'),
          null,
        ),
      );
      ClipboardFile file(int size, List<int> bytes) => ClipboardFile(
        name: 'photo.png',
        mime: 'image/png',
        size: size,
        read: () => Stream.value(Uint8List.fromList(bytes)),
      );
      await copyMediaFiles([
        file(3, [1, 2, 3]),
      ]);
      expect(operations.map((c) => c.method), ['begin', 'write', 'commit']);
      expect(operations[1].arguments['bytes'], [1, 2, 3]);
      for (final size in [2, 4]) {
        operations.clear();
        await expectLater(
          copyMediaFiles([
            file(size, [1, 2, 3]),
          ]),
          throwsStateError,
        );
        expect(operations.last.method, 'cancel');
        expect(operations.any((c) => c.method == 'commit'), false);
      }
    },
  );
  testWidgets(
    'Copy pulse preserves geometry and repeats; reduced motion has no ticker',
    (tester) async {
      var pulse = 0;
      var reduced = false;
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Center(
              child: CopyFeedback(
                pulse: pulse,
                child: const SizedBox(width: 240, height: 120),
              ),
            ),
          ),
        ),
      );
      await show();
      final original = tester.getRect(find.byType(CopyFeedback));
      for (var i = 0; i < 2; i++) {
        pulse++;
        await show();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.getRect(find.byType(CopyFeedback)), original);
        await tester.pumpAndSettle();
      }
      reduced = true;
      await show();
      pulse++;
      await show();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Active call banner is actionable and static with reduced motion on a small screen',
    (tester) async {
      var taps = 0;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              disableAnimations: true,
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: ActiveCallBanner(
                label: 'Идёт звонок · Вернуться к звонку',
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
