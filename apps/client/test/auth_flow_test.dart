import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/registration_screen.dart';
import 'package:voicechat_probe/theme.dart';
import 'registration_screen_test.dart'
    show RegistrationClient, field, fillAccount, send;

class AuthClient extends RegistrationClient {
  final attempts = <int>[];
  final addresses = <String>[];
  int resets = 0;
  bool confirmed = false;
  bool? loggedOut;
  mx.AuthenticationData? lastAuth;
  @override
  Future<mx.RequestTokenResponse> requestTokenToRegisterEmail(
    String secret,
    String email,
    int attempt, {
    Uri? nextLink,
    String? idAccessToken,
    String? idServer,
  }) async {
    attempts.add(attempt);
    addresses.add(email);
    return mx.RequestTokenResponse(sid: 'session-$attempt');
  }

  @override
  Future<mx.RequestTokenResponse> requestTokenToResetPasswordEmail(
    String secret,
    String email,
    int attempt, {
    Uri? nextLink,
    String? idAccessToken,
    String? idServer,
  }) => requestTokenToRegisterEmail(secret, email, attempt);
  @override
  Future<void> changePassword(
    String password, {
    String? oldPassword,
    mx.AuthenticationData? auth,
    bool? logoutDevices,
  }) async {
    resets++;
    lastAuth = auth;
    loggedOut = logoutDevices;
    if (!confirmed) {
      throw mx.MatrixException.fromJson({
        'errcode': 'M_THREEPID_AUTH_FAILED',
        'session': 'server-uia',
      });
    }
  }
}

void main() {
  testWidgets(
    'Registration validates locally, retains values and restarts email verification explicitly',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = AuthClient();
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: RegistrationScreen(
            openClient: (_) async {
              opens++;
              return client;
            },
          ),
        ),
      );
      await send(tester);
      expect(opens, 0);
      expect(find.text('Введите адрес электронной почты.'), findsOneWidget);
      await fillAccount(tester);
      await send(tester);
      expect(find.text('Проверьте вашу почту'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('test@example.com'), findsOneWidget);
      await tester.tap(find.text('Изменить данные'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(field('Логин · строчные a–z'))
            .controller!
            .text,
        'testuser',
      );
      expect(
        tester
            .widget<TextField>(field('Пароль аккаунта · от 12 символов'))
            .controller!
            .text,
        'account password',
      );
      await tester.enterText(field('Электронная почта'), 'correct@example.com');
      await send(tester);
      expect(client.attempts, [1, 2]);
      expect(client.addresses, ['test@example.com', 'correct@example.com']);
      expect(opens, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Reset requires server email proof and keeps logoutDevices and UIA session',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1100);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = AuthClient();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: RegistrationScreen(
            resetPassword: true,
            openClient: (_) async => client,
          ),
        ),
      );
      expect(field('Логин · строчные a–z'), findsNothing);
      await tester.enterText(field('Электронная почта'), 'reset@example.com');
      await tester.enterText(
        field('Пароль аккаунта · от 12 символов'),
        'new secure password',
      );
      await tester.enterText(field('Повторите пароль'), 'new secure password');
      await send(tester);
      final confirm = find.text('Почта подтверждена · сменить пароль');
      await tester.pump(const Duration(seconds: 15));
      expect(client.resets, 0, reason: 'Password reset must remain explicit');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(client.resets, 1);
      expect(client.loggedOut, true);
      expect(
        find.text('Сначала подтвердите адрес по ссылке из письма.'),
        findsOneWidget,
      );
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(client.lastAuth!.toJson()['session'], 'server-uia');
      final creds = client.lastAuth!.toJson()['threepid_creds'] as Map;
      expect(creds['sid'], 'session-1');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Auth forms remain usable with large text and keyboard in portrait and landscape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final size in [
        const Size(320, 568),
        const Size(844, 390),
        const Size(1440, 900),
      ]) {
        tester.view.physicalSize = size;
        for (final reset in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: AppPalette.halo.theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(2),
                  viewInsets: const EdgeInsets.only(bottom: 180),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: RegistrationScreen(
                key: ValueKey('$size-$reset'),
                resetPassword: reset,
                openClient: (_) async => AuthClient(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Отправить письмо'));
          await tester.pumpAndSettle();
          expect(find.text('Отправить письмо').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '$size reset=$reset');
        }
      }
    },
  );
}
