import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/native_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeNotifications.channel, (call) async {
          calls.add(call);
          return call.method == 'request' ? false : null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeNotifications.channel, null);
  });

  test('permission denial does not persist consent', () async {
    final notifications = NativeNotifications('alice', (_) async {});
    await notifications.open();
    expect(calls.map((call) => call.method), ['begin', 'enabled']);
    expect(await notifications.setEnabled(true), contains('Разрешите'));
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'macosNotifications:alice',
      ),
      isNull,
    );
    expect(
      calls
          .where((call) => call.method == 'enabled')
          .single
          .arguments['enabled'],
      false,
    );
    await notifications.close();
  });

  test(
    'Android requests permission and persists consent for the current account',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(NativeNotifications.supported, isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeNotifications.channel, (call) async {
            calls.add(call);
            return call.method == 'request' ? true : null;
          });
      final notifications = NativeNotifications('alice', (_) async {});
      await notifications.open();
      expect(await notifications.setEnabled(true), contains('включены'));
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'androidNotifications:alice',
        ),
        isTrue,
      );
      await notifications.message('!room', 'event');
      expect(calls.last.method, 'show');
      expect(calls.last.arguments, {
        'session': notifications.session,
        'room': '!room',
        'id': 'event',
        'call': false,
      });
      await notifications.close();
      expect(calls.last.method, 'end');
    },
  );

  test('old-account click cannot open a chat in the next session', () async {
    final opened = <String>[];
    final first = NativeNotifications(
      'alice',
      (room) async => opened.add(room),
    );
    await first.open();
    final ended = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeNotifications.channel, (call) async {
          calls.add(call);
          if (call.method == 'end' &&
              call.arguments['session'] == first.session) {
            await ended.future;
          }
          return null;
        });
    final closing = first.close();
    final second = NativeNotifications('bob', (room) async => opened.add(room));
    await second.open();
    ended.complete();
    await closing;
    expect(first.session, isNot(second.session));
    Future<void> click(String session) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            NativeNotifications.channel.name,
            codec.encodeMethodCall(
              MethodCall('open', {'session': session, 'room': '!room'}),
            ),
            (_) {},
          );
    }

    await click(first.session);
    expect(opened, isEmpty);
    await click(second.session);
    expect(opened, ['!room']);
    await second.close();
    final count = calls.length;
    await second.message('!room', 'event');
    expect(calls.length, count);
  });

  test(
    'Android binds push after permission and removes it before logout',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final requests = <String>[];
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer matrix-token');
        final body = jsonDecode(request.body) as Map;
        requests.add(body['action'] as String);
        if (body['action'] == 'register') {
          expect(body['token'], 'installation-token');
          return http.Response(jsonEncode({'binding': 'b' * 43}), 200);
        }
        return http.Response('{"ok":true}', 200);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeNotifications.channel, (call) async {
            calls.add(call);
            if (call.method == 'request') return true;
            if (call.method == 'pushToken') return 'installation-token';
            return null;
          });
      final notifications = NativeNotifications(
        'alice',
        (_) async {},
        pushUrl: 'https://voice.example/api',
        accessToken: 'matrix-token',
        transport: client,
      );
      await notifications.open();
      expect(
        await notifications.setEnabled(true),
        'Фоновые уведомления включены.',
      );
      expect(
        calls.where((c) => c.method == 'pushBind').single.arguments['account'],
        'alice',
      );
      await notifications.close();
      expect(requests, ['register', 'remove']);
      expect(
        calls.map((c) => c.method),
        containsAllInOrder(['pushClear', 'end']),
      );
      client.close();
    },
  );

  test('failed push registration does not persist consent', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final client = MockClient(
      (_) async => http.Response('{"error":"unavailable"}', 503),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeNotifications.channel, (call) async {
          calls.add(call);
          if (call.method == 'request') return true;
          if (call.method == 'pushToken') return 'installation-token';
          return null;
        });
    final notifications = NativeNotifications(
      'alice',
      (_) async {},
      pushUrl: 'https://voice.example/api',
      accessToken: 'matrix-token',
      transport: client,
    );
    await notifications.open();
    expect(await notifications.setEnabled(true), contains('Не удалось'));
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'androidNotifications:alice',
      ),
      isNull,
    );
    expect(calls.where((c) => c.method == 'pushBind'), isEmpty);
    await notifications.close();
    client.close();
  });

  test(
    'logout during registration cannot restore the native push binding',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final started = Completer<void>();
      final release = Completer<void>();
      final requests = <String>[];
      final client = MockClient((request) async {
        final action = (jsonDecode(request.body) as Map)['action'] as String;
        requests.add(action);
        if (action == 'register') {
          started.complete();
          await release.future;
          return http.Response(jsonEncode({'binding': 'b' * 43}), 200);
        }
        return http.Response('{"ok":true}', 200);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeNotifications.channel, (call) async {
            calls.add(call);
            if (call.method == 'request') return true;
            if (call.method == 'pushToken') return 'installation-token';
            return null;
          });
      final notifications = NativeNotifications(
        'alice',
        (_) async {},
        pushUrl: 'https://voice.example/api',
        accessToken: 'matrix-token',
        transport: client,
      );
      await notifications.open();
      final enabling = notifications.setEnabled(true);
      await started.future;
      final closing = notifications.close();
      release.complete();
      await enabling;
      await closing;
      expect(calls.where((c) => c.method == 'pushBind'), isEmpty);
      expect(requests, ['register', 'remove']);
      client.close();
    },
  );
}
