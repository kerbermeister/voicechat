import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/registration_screen.dart';
import 'package:voicechat_probe/theme.dart';
import 'registration_screen_test.dart'
    show RegistrationClient, fillAccount, send, field;

class AutoRegistrationClient extends RegistrationClient {
  bool confirmed = false, logged = false;
  int registrations = 0, profileWrites = 0;
  String? failCode;
  int? retryMs;
  bool failFirstProfileWrite = false;
  Completer<void>? gate;
  final auths = <Map<String, Object?>>[];
  final devices = <String?>[];
  @override
  bool isLogged() => logged;
  @override
  String? get deviceID => null;
  @override
  Future get firstSyncReceived => Future<void>.value();
  @override
  String get userID => '@testuser:local';
  @override
  Future<Map<String, Object?>> setProfileField(
    String userId,
    String field,
    Map<String, Object?> content,
  ) async {
    profileWrites++;
    if (failFirstProfileWrite && profileWrites == 1) {
      throw StateError('profile unavailable');
    }
    return {};
  }

  @override
  Future<mx.RegisterResponse> register({
    String? username,
    String? password,
    String? deviceId,
    String? initialDeviceDisplayName,
    bool? inhibitLogin,
    bool? refreshToken,
    mx.AuthenticationData? auth,
    mx.AccountKind? kind,
    void Function(mx.InitState)? onInitStateChanged,
  }) async {
    registrations++;
    auths.add(auth!.toJson());
    devices.add(deviceId);
    await gate?.future;
    if (failCode != null) {
      throw mx.MatrixException.fromJson({
        'errcode': failCode,
        'retry_after_ms': retryMs,
      });
    }
    if (!confirmed) {
      throw mx.MatrixException.fromJson({
        'errcode': 'M_UNAUTHORIZED',
        'session': 'server-uia',
        'flows': [
          {
            'stages': ['m.login.email.identity'],
          },
        ],
      });
    }
    logged = true;
    return mx.RegisterResponse(
      userId: '@testuser:local',
      accessToken: 'test-token',
      deviceId: deviceId!,
    );
  }
}

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = const Size(1100, 1000);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });
  Future<void> open(
    WidgetTester tester,
    AutoRegistrationClient client,
    void Function(String) onRegistered,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppPalette.halo.theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final result = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RegistrationScreen(
                      openClient: (_) async => client,
                      onRegistered: onRegistered,
                    ),
                  ),
                );
                if (result == true && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Registration finished')),
                  );
                }
              },
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await fillAccount(tester);
    if (client.failFirstProfileWrite) {
      await tester.enterText(field('Отображаемое имя (необязательно)'), 'Test');
    }
    await send(tester);
    expect(find.text('Почта подтверждена · создать аккаунт'), findsNothing);
  }

  Future<void> tick(WidgetTester tester, Duration delay) async {
    await tester.pump(delay);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'Email confirmation completes the original form without a click; retries retain session, credentials and device ID',
    (tester) async {
      final client = AutoRegistrationClient();
      int finished = 0;
      await open(tester, client, (_) => finished++);
      await tick(tester, const Duration(seconds: 3));
      expect(client.registrations, 1);
      expect(finished, 0);
      expect(client.logged, false);
      expect(find.byType(RegistrationScreen), findsOneWidget);
      client.confirmed = true;
      await tick(tester, const Duration(seconds: 3));
      expect(finished, 1);
      expect(client.logged, true);
      expect(find.byType(RegistrationScreen), findsNothing);
      expect(client.auths.last['session'], 'server-uia');
      expect(
        client.auths.first['threepid_creds'],
        client.auths.last['threepid_creds'],
      );
      expect(client.devices.toSet().length, 1);
      expect(client.devices.first, isNotEmpty);
      await tick(tester, const Duration(seconds: 30));
      expect(finished, 1);
      expect(client.registrations, 2);
    },
  );
  testWidgets(
    'A retry after SDK login and profile failure does not create a second registration',
    (tester) async {
      final client = AutoRegistrationClient()
        ..confirmed = true
        ..failFirstProfileWrite = true;
      int finished = 0;
      await open(tester, client, (_) => finished++);
      await tick(tester, const Duration(seconds: 3));
      expect(client.registrations, 1);
      expect(finished, 0);
      await tick(tester, const Duration(seconds: 6));
      expect(client.registrations, 1);
      expect(finished, 1);
      expect(client.profileWrites, 2);
    },
  );
  testWidgets('Temporary server errors retry automatically', (tester) async {
    final client = AutoRegistrationClient()..failCode = 'M_UNKNOWN';
    int finished = 0;
    await open(tester, client, (_) => finished++);
    await tick(tester, const Duration(seconds: 3));
    expect(finished, 0);
    client.failCode = null;
    client.confirmed = true;
    await tick(tester, const Duration(seconds: 6));
    expect(finished, 1);
    expect(client.registrations, 2);
  });
  testWidgets('Server retry_after_ms is respected before another check', (
    tester,
  ) async {
    final client = AutoRegistrationClient()
      ..failCode = 'M_LIMIT_EXCEEDED'
      ..retryMs = 12000;
    int finished = 0;
    await open(tester, client, (_) => finished++);
    await tick(tester, const Duration(seconds: 3));
    expect(client.registrations, 1);
    client.failCode = null;
    client.confirmed = true;
    await tick(tester, const Duration(seconds: 8));
    expect(client.registrations, 1);
    expect(finished, 0);
    await tick(tester, const Duration(seconds: 4));
    expect(finished, 1);
    expect(client.registrations, 2);
  });
  testWidgets(
    'Background checks pause; returning from mail completes automatically',
    (tester) async {
      final client = AutoRegistrationClient();
      int finished = 0;
      await open(tester, client, (_) => finished++);
      await tick(tester, const Duration(seconds: 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      client.confirmed = true;
      await tick(tester, const Duration(seconds: 30));
      expect(client.registrations, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tick(tester, Duration.zero);
      expect(finished, 1);
    },
  );
  testWidgets(
    'Fatal errors stop automatic attempts and allow changing account data',
    (tester) async {
      final client = AutoRegistrationClient()..failCode = 'M_USER_IN_USE';
      int finished = 0;
      await open(tester, client, (_) => finished++);
      await tick(tester, const Duration(seconds: 3));
      expect(find.textContaining('Это имя уже занято'), findsOneWidget);
      await tick(tester, const Duration(seconds: 30));
      expect(client.registrations, 1);
      expect(finished, 0);
      await tester.tap(find.text('Изменить данные'));
      await tester.pumpAndSettle();
      expect(field('Электронная почта'), findsOneWidget);
    },
  );
  testWidgets(
    'Leaving during a check cancels future polling and cannot finish another screen',
    (tester) async {
      final client = AutoRegistrationClient()
        ..confirmed = true
        ..gate = Completer<void>();
      int finished = 0;
      await open(tester, client, (_) => finished++);
      await tick(tester, const Duration(seconds: 3));
      expect(client.registrations, 1);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      client.gate!.complete();
      await tester.pumpAndSettle();
      await tick(tester, const Duration(seconds: 30));
      expect(finished, 0);
      expect(client.registrations, 1);
      expect(find.text('Start'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
