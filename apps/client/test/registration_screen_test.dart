import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';
import 'package:voicechat_probe/registration_screen.dart';
import 'package:voicechat_probe/user_action_error.dart';

class RegistrationClient implements mx.Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  int requests = 0;

  @override
  Future<mx.RequestTokenResponse> requestTokenToRegisterEmail(
    String clientSecret,
    String email,
    int sendAttempt, {
    Uri? nextLink,
    String? idAccessToken,
    String? idServer,
  }) async {
    requests++;
    return mx.RequestTokenResponse(sid: 'test-session');
  }
}

Finder field(String label) => find.widgetWithText(TextField, label);

Future<void> fillAccount(WidgetTester tester) async {
  await tester.enterText(field('Имя пользователя · латиницей'), 'testuser');
  await tester.enterText(field('Электронная почта'), 'test@example.com');
  await tester.enterText(
    field('Пароль аккаунта · от 12 символов'),
    'account password',
  );
  await tester.enterText(field('Повторите пароль'), 'account password');
}

Future<void> send(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Отправить письмо'));
  await tester.tap(find.text('Отправить письмо'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = const Size(900, 1400);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });
  testWidgets(
    'Create account opens without opening a store or entering a phrase',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const VoiceChatApp());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Создать аккаунт'));
      await tester.tap(find.text('Создать аккаунт'));
      await tester.pumpAndSettle();
      expect(find.byType(RegistrationScreen), findsOneWidget);
      expect(field('Электронная почта'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      expect(find.byType(RegistrationScreen), findsNothing);
    },
  );

  testWidgets(
    'Web phrase validates on registration before opening store or sending email',
    (tester) async {
      var opens = 0;
      String? openedPhrase;
      final client = RegistrationClient();
      await tester.pumpWidget(
        MaterialApp(
          home: RegistrationScreen(
            requireLocalPassphrase: true,
            openClient: (phrase) async {
              opens++;
              openedPhrase = phrase;
              return client;
            },
          ),
        ),
      );
      expect(opens, 0);
      await fillAccount(tester);
      for (final phrase in ['', 'short', 'x' * 1025, 'account password']) {
        await tester.ensureVisible(field('Локальная фраза · от 12 символов'));
        await tester.enterText(
          field('Локальная фраза · от 12 символов'),
          phrase,
        );
        await send(tester);
        expect(opens, 0);
        expect(client.requests, 0);
        expect(
          find.text(
            phrase == 'account password'
                ? 'Придумайте фразу, отличную от пароля аккаунта.'
                : 'Введите локальную фразу от 12 до 1024 символов.',
          ),
          findsOneWidget,
        );
      }
      await tester.ensureVisible(field('Локальная фраза · от 12 символов'));
      await tester.enterText(
        field('Локальная фраза · от 12 символов'),
        'separate local phrase',
      );
      await send(tester);
      expect(opens, 1);
      expect(openedPhrase, 'separate local phrase');
      expect(client.requests, 1);
      expect(find.text('Почта подтверждена · создать аккаунт'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Storage errors are shown and allow correcting the phrase', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RegistrationScreen(
          requireLocalPassphrase: true,
          openClient: (_) async =>
              throw UserActionError('Данные сохранены. Проверьте фразу.'),
        ),
      ),
    );
    await fillAccount(tester);
    await tester.enterText(
      field('Локальная фраза · от 12 символов'),
      'incorrect local phrase',
    );
    await send(tester);
    expect(find.text('Данные сохранены. Проверьте фразу.'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(field('Локальная фраза · от 12 символов'))
          .readOnly,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('Leaving while opening the store does not send email', (
    tester,
  ) async {
    final opening = Completer<mx.Client>();
    final client = RegistrationClient();
    await tester.pumpWidget(
      MaterialApp(
        home: RegistrationScreen(
          requireLocalPassphrase: true,
          openClient: (_) => opening.future,
        ),
      ),
    );
    await fillAccount(tester);
    await tester.enterText(
      field('Локальная фраза · от 12 символов'),
      'separate local phrase',
    );
    await tester.tap(find.text('Отправить письмо'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    opening.complete(client);
    await tester.pumpAndSettle();
    expect(client.requests, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Registration phrase and submit remain reachable at narrow widths',
    (tester) async {
      for (final size in [const Size(375, 844), const Size(844, 375)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            home: RegistrationScreen(
              key: ValueKey(size),
              requireLocalPassphrase: true,
              openClient: (_) async => throw StateError('Must not open'),
            ),
          ),
        );
        await tester.scrollUntilVisible(
          field('Локальная фраза · от 12 символов'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.scrollUntilVisible(
          find.text('Отправить письмо'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Отправить письмо').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
