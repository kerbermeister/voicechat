import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart' as app;
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/first_keys.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/lab_messaging.dart' show testImage, testVoice;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android narrow chat, keyboard, emoji, group and profile layout', (
    tester,
  ) async {
    const username = String.fromEnvironment('UI_USERNAME');
    const password = String.fromEnvironment('UI_PASSWORD');
    expect(
      username.isNotEmpty && password.isNotEmpty,
      true,
      reason: 'Provide disposable UI fixture via dart-define-from-file',
    );
    final profile = 'native-layout-${DateTime.now().millisecondsSinceEpoch}';
    final probe = await MatrixProbe.open(profile);
    await probe.login('http://localhost:8008', username, password);
    enableFirstContactTrust(probe.client);
    final room = await probe.room(
      await probe.createRoom([], name: 'Мобильная проверка'),
    );
    final actions = ChatActions(probe.client);
    await actions.open();
    await actions.text(room, 'Проверяем читаемость сообщений и вложений');
    await actions.attachment(
      room,
      mx.MatrixImageFile(
        bytes: testImage,
        name: 'photo.png',
        mimeType: 'image/png',
      ),
    );
    await actions.attachment(
      room,
      mx.MatrixAudioFile(
        bytes: testVoice,
        name: 'voice.wav',
        mimeType: 'audio/wav',
        duration: 100,
      ),
      waveform: [0, 100, 500, 900, 500, 100, 0],
    );
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (actions.pending.isNotEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect(actions.pending, isEmpty);
    await actions.close();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'lastAccount',
      jsonEncode({
        'profile': profile,
        'username': probe.client.userID,
        'server': 'http://localhost:8008',
        'tokenServer': 'http://localhost:8090',
        'mediaServer': 'ws://localhost:7880',
      }),
    );
    await prefs.setString('lastRoom:$profile', room.id);
    await probe.close();
    await app.main();
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 300 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(finder, findsWidgets);
    }

    await waitFor(find.text('Открыть переписку'));
    await tester.tap(find.text('Открыть переписку'));
    await waitFor(find.byTooltip('Отправить'));
    Future<void> screenshot(String name) async {
      await tester.pump(const Duration(milliseconds: 400));
      var done = false;
      final capture = binding
          .takeScreenshot(name)
          .whenComplete(() => done = true);
      for (var i = 0; i < 200 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(done, true, reason: 'Native screenshot did not finish: $name');
      await capture;
    }

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await screenshot('chat');
    final field = find.widgetWithText(TextField, 'Написать сообщение…');
    await tester.tap(field);
    await tester.enterText(field, 'Подпись к новому сообщению');
    tester.view.viewInsets = FakeViewPadding(
      bottom: 250 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);
    await tester.pump(const Duration(milliseconds: 400));
    final send = tester.getRect(find.byTooltip('Отправить'));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(send.left, greaterThanOrEqualTo(0));
    expect(send.right, lessThanOrEqualTo(width));
    expect(tester.getSize(field).width, greaterThan(100));
    expect(tester.takeException(), isNull);
    await screenshot('composer');
    await tester.tap(find.byTooltip('Отправить'));
    await tester.enterText(field, 'Следующий черновик');
    await waitFor(find.text('Подпись к новому сообщению'));
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Следующий черновик',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    tester.view.resetViewInsets();
    await tester.pump(const Duration(milliseconds: 300));
    // Presence and typing animate continuously; wait for controls rather than global idleness.
    await tester.tap(find.byTooltip('Эмодзи'));
    await tester.pump(const Duration(milliseconds: 400));
    await screenshot('emoji');
    await tester.tap(find.text('😀').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Участники и настройки чата'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Вступили · 1'), findsOneWidget);
    await screenshot('members');
    await tester.tap(find.text('Закрыть').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Закрыть чат'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(PersonAvatar).first);
    await waitFor(find.text('Мой профиль'));
    await screenshot('profile');
    expect(find.byType(SwitchListTile), findsNothing);
    await tester.tap(find.text('Закрыть').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Настройки'));
    await waitFor(find.byType(SwitchListTile));
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pump(const Duration(milliseconds: 400));
    await screenshot('privacy-settings');
    await tester.tap(find.byType(SwitchListTile));
    await waitFor(
      find.byWidgetPredicate(
        (w) => w is SwitchListTile && !w.value && w.onChanged != null,
      ),
    );
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(SwitchListTile));
    await waitFor(
      find.byWidgetPredicate(
        (w) => w is SwitchListTile && w.value && w.onChanged != null,
      ),
    );
    await tester.tap(find.text('Закрыть').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Действия с чатом').first);
    await tester.pump(const Duration(milliseconds: 400));
    await screenshot('chat-menu');
    await tester.tap(find.text('Отключить уведомления'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Действия с чатом').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Включить уведомления'), findsOneWidget);
    await tester.tap(find.text('Включить уведомления'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Действия с чатом').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Информация'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Закрыть').last);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
