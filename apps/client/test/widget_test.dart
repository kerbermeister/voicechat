import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';

void main() {
  testWidgets(
    'Halo is default; palette switch persists without overflow on narrow screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const VoiceChatApp());
      await tester.pumpAndSettle();
      expect(find.text('VoiceChat'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.text('VoiceChat'))).colorScheme.surface,
        const Color(0xFF101A35),
      );
      await tester.tap(find.byTooltip('Цветовая схема'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Midnight'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('VoiceChat'));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(
        (await SharedPreferences.getInstance()).getString('palette'),
        'midnight',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Saved profile restores account and connection without asking for account password',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'lastAccount': jsonEncode({
          'username': '@anna:local',
          'profile': 'annas-browser',
          'server': 'http://localhost:8008',
          'tokenServer': 'http://localhost:8090',
          'mediaServer': 'ws://localhost:7880',
        }),
      });
      await tester.pumpWidget(const VoiceChatApp());
      await tester.pumpAndSettle();
      expect(find.text('@anna:local'), findsOneWidget);
      expect(find.text('Открыть переписку'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Пароль аккаунта'), findsNothing);
      await tester.tap(find.byTooltip('Параметры подключения'));
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(
        find.widgetWithText(TextField, 'Профиль устройства'),
        findsNothing,
      );
      expect(fields.any((f) => f.controller?.text == 'annas-browser'), false);
      expect(
        fields.any((f) => f.controller?.text == 'http://localhost:8008'),
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
