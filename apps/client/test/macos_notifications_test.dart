import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/macos_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSNotifications.channel, (call) async {
          calls.add(call);
          return call.method == 'request' ? false : null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSNotifications.channel, null);
  });

  test('permission denial does not persist consent', () async {
    final notifications = MacOSNotifications('alice', (_) async {});
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

  test('old-account click cannot open a chat in the next session', () async {
    final opened = <String>[];
    final first = MacOSNotifications('alice', (room) async => opened.add(room));
    await first.open();
    final ended = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MacOSNotifications.channel, (call) async {
          calls.add(call);
          if (call.method == 'end' &&
              call.arguments['session'] == first.session) {
            await ended.future;
          }
          return null;
        });
    final closing = first.close();
    final second = MacOSNotifications('bob', (room) async => opened.add(room));
    await second.open();
    ended.complete();
    await closing;
    expect(first.session, isNot(second.session));
    Future<void> click(String session) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            MacOSNotifications.channel.name,
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
}
