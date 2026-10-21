import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';

void main() {
  testWidgets(
    'Lavender is default; palette switch persists without overflow on narrow screen',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const VoiceChatApp());
      await tester.pumpAndSettle();
      expect(find.text('VoiceChat'), findsOneWidget);
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
}
