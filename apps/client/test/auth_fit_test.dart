import 'test_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';
import 'package:voicechat_probe/registration_screen.dart';
import 'package:voicechat_probe/theme.dart';
import 'registration_screen_test.dart'
    show RegistrationClient, fillAccount, send;

void main() {
  testWidgets(
    'Auth screens stay centered and fit the viewport without scrolling',
    (tester) async {
      await loadAppFont();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final overflowing = <String, double>{};
      for (final size in [
        const Size(320, 568),
        const Size(390, 667),
        const Size(390, 844),
        const Size(768, 700),
        const Size(320, 844),
        const Size(1366, 768),
        const Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        for (final screen in ['login', 'register', 'reset']) {
          SharedPreferences.setMockInitialValues({});
          await tester.pumpWidget(
            screen == 'login'
                ? const VoiceChatApp()
                : MaterialApp(
                    theme: AppPalette.halo.theme,
                    home: RegistrationScreen(
                      key: ValueKey(screen),
                      resetPassword: screen == 'reset',
                      openClient: (_) async => RegistrationClient(),
                    ),
                  ),
          );
          await tester.pumpAndSettle();
          void expectCentered() {
            final center = tester.getCenter(
              find.byKey(const ValueKey('auth-card')),
            );
            expect(
              center.dx,
              closeTo(size.width / 2, .5),
              reason: '$screen horizontal center at $size',
            );
            expect(
              center.dy,
              closeTo(size.height / 2, .5),
              reason: '$screen vertical center at $size',
            );
          }

          expectCentered();
          final scroll = tester.state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(SingleChildScrollView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          if (scroll.position.maxScrollExtent > 0) {
            overflowing['$screen at $size'] = scroll.position.maxScrollExtent;
          }
          expect(
            find
                .text(
                  screen == 'login' ? 'Создать аккаунт' : 'Отправить письмо',
                )
                .hitTestable(),
            findsOneWidget,
          );
          if (screen == 'register') {
            await fillAccount(tester);
            await send(tester);
            expectCentered();
            expect(
              scroll.position.maxScrollExtent,
              0,
              reason: 'email confirmation at $size',
            );
            expect(find.text('Изменить данные').hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      expect(overflowing, isEmpty);
    },
  );
}
