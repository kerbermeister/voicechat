import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:voicechat_probe/file_io.dart';
import 'package:voicechat_probe/recovery_key_dialog.dart';
import 'package:voicechat_probe/theme.dart';

const fakeKey = 'FAKE recovery key for UI testing only';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('voicechat/save');
  test(
    'Text export preserves UTF-8 exactly, closes writes, and distinguishes cancellation and failure',
    () async {
      final calls = <MethodCall>[];
      String? id = 'file';
      bool failWrite = false, failClose = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'begin') return id;
            if (call.method == 'write' && failWrite ||
                call.method == 'finish' && failClose) {
              throw PlatformException(code: 'save');
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(
        await saveTextFile(recoveryKeyFileName, '$fakeKey · ключ'),
        FileSaveResult.saved,
      );
      expect(calls[0].arguments, {
        'name': recoveryKeyFileName,
        'mime': 'text/plain',
      });
      expect(
        utf8.decode(calls[1].arguments['bytes'] as Uint8List),
        '$fakeKey · ключ',
      );
      expect(calls[2].arguments, {'id': 'file', 'success': true});
      // Exercise the SDK recovery-key codec using synthetic bytes, never a real account key.
      final original = Uint8List.fromList(List.generate(32, (i) => i));
      final recovery = SSSS.encodeRecoveryKey(original);
      calls.clear();
      await saveTextFile(recoveryKeyFileName, recovery);
      final restored = utf8.decode(calls[1].arguments['bytes'] as Uint8List);
      expect(SSSS.decodeRecoveryKey(restored), original);
      calls.clear();
      id = null;
      expect(
        await saveTextFile(recoveryKeyFileName, fakeKey),
        FileSaveResult.cancelled,
      );
      expect(calls.length, 1);
      calls.clear();
      id = 'file';
      failWrite = true;
      await expectLater(
        saveTextFile(recoveryKeyFileName, fakeKey),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.last.arguments, {'id': 'file', 'success': false});
      failWrite = false;
      failClose = true;
      await expectLater(
        saveTextFile(recoveryKeyFileName, fakeKey),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  testWidgets(
    'Key is read-only; copy and save report only confirmed success; fits small screens',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      bool denyCopy = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (denyCopy) throw PlatformException(code: 'denied');
            copied = call.arguments['text'] as String;
          }
          return null;
        },
      );
      String? id;
      bool failSave = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (failSave) throw PlatformException(code: 'denied');
        return call.method == 'begin' ? id : null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.halo.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(body: RecoveryKeyDialog(recoveryKey: fakeKey)),
          ),
        );
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.readOnly, true);
        expect(field.controller!.text, fakeKey);
        final copy = find.widgetWithText(OutlinedButton, 'Скопировать ключ');
        final save = find.widgetWithText(OutlinedButton, 'Сохранить в файл');
        await tester.ensureVisible(copy);
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(copied, fakeKey);
        expect(find.text('Ключ скопирован.'), findsOneWidget);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.text('Файл сохранён.'), findsNothing);
        id = 'file';
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.text('Файл сохранён.'), findsOneWidget);
        failSave = true;
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(find.text('Файл сохранён.'), findsNothing);
        expect(
          find.textContaining('Не удалось сохранить файл'),
          findsOneWidget,
        );
        denyCopy = true;
        await tester.ensureVisible(copy);
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Не удалось скопировать ключ'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        id = null;
        failSave = false;
        denyCopy = false;
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
