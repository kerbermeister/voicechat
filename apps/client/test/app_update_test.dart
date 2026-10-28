import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicechat_probe/app_update.dart';
import 'package:voicechat_probe/app_update_dialog.dart';
import 'package:voicechat_probe/update_platform_native.dart';
import 'package:voicechat_probe/route_transport.dart';

const package = 'dev.voicechat.voicechat_probe';
Map<String, dynamic> manifest([List<int> bytes = const [1, 2, 3]]) => {
  'schema': 1,
  'applicationId': package,
  'versionName': '1.2.0',
  'versionCode': 3,
  'minSdk': 24,
  'sizeBytes': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  'apkPath': '/updates/android/3/voicechat.apk',
  'notes': 'Исправления и улучшения.',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('strict manifest and escaped duplicate keys', () {
    expect(AppUpdate.parse(jsonEncode(manifest()), package).versionCode, 3);
    for (final patch in <Map<String, dynamic>>[
      {'schema': 2},
      {'schema': 1.0},
      {'versionCode': 3.0},
      {'versionCode': -1},
      {'applicationId': 'other'},
      {'apkPath': '/updates/android/3/../voicechat.apk'},
      {'apkPath': 'https://evil.test/a.apk'},
      {'apkPath': '/updates/android/3/voicechat.apk?x'},
      {'sizeBytes': maxApkBytes + 1},
      {'sizeBytes': 0},
      {'sha256': 'bad'},
      {'versionName': '01.2.3'},
      {'minSdk': true},
      {'notes': 'x' * 4001},
    ]) {
      expect(
        () => AppUpdate.parse(jsonEncode({...manifest(), ...patch}), package),
        throwsFormatException,
        reason: '$patch',
      );
    }
    final duplicated = jsonEncode(
      manifest(),
    ).replaceFirst('{', '{"versionCode":2,');
    expect(() => AppUpdate.parse(duplicated, package), throwsFormatException);
    final escaped = jsonEncode(
      manifest(),
    ).replaceFirst('{', r'{"version\u0043ode":2,');
    expect(() => AppUpdate.parse(escaped, package), throwsFormatException);
    final quoted = {
      ...manifest(),
      'notes': 'Текст "versionCode": 7, не поле JSON.',
    };
    expect(AppUpdate.parse(jsonEncode(quoted), package).notes, quoted['notes']);
  });

  test('HTTPS fixed origin, no credentials or redirects', () async {
    for (final origin in [
      'http://localhost',
      'https://x/y',
      'https://a@b',
      'https://x?y',
      'https://x#f',
    ]) {
      expect(
        () => updateUrl(origin, '/updates/android/latest.json'),
        throwsFormatException,
      );
    }
    final client = MockClient((request) async {
      expect(request.followRedirects, false);
      expect(request.headers.containsKey('authorization'), false);
      return http.Response('', 302, headers: {'location': 'https://evil.test'});
    });
    await expectLater(
      checkAppUpdate(client, 'https://updates.test', package),
      throwsFormatException,
    );
    client.close();
  });

  test('oversized metadata and HTML are errors, never no-update', () async {
    for (final source in ['x' * 65537, '<html>SPA</html>']) {
      final client = MockClient((_) async => http.Response(source, 200));
      await expectLater(
        checkAppUpdate(client, 'https://updates.test', package),
        throwsFormatException,
      );
      client.close();
    }
  });

  test(
    'routed update pins selected metadata and rejects mismatching bytes on another entry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'routed-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final b = Uri.parse('https://b.test'), c = Uri.parse('https://c.test');
      final requests = <Uri>[];
      var wrongPackage = true;
      final network = RouteTransport(
        origin: Uri.parse('https://updates.test'),
        routes: [b, c],
        inner: MockClient((request) async {
          requests.add(request.url);
          expect(request.followRedirects, false);
          expect(request.headers.containsKey('authorization'), false);
          if (request.url.path.endsWith('/latest.json')) {
            expect(request.url.origin, b.origin);
            return http.Response.bytes(
              utf8.encode(jsonEncode(manifest())),
              200,
            );
          }
          expect(request.url.origin, c.origin);
          expect(request.url.path, '/updates/android/3/voicechat.apk');
          return http.Response.bytes(wrongPackage ? [3, 2, 1] : [1, 2, 3], 200);
        }),
      );
      addTearDown(network.close);
      final selected = await checkAppUpdate(
        network,
        'https://updates.test',
        package,
      );
      network.select(c);
      final path = '${directory.path}/update.apk';
      Future<void> download() => downloadUpdate(
        network,
        'https://updates.test',
        selected,
        path,
        (_) {},
        () => false,
      );
      await expectLater(download(), throwsFormatException);
      expect(await File(path).exists(), false);
      expect(requests, hasLength(2));
      wrongPackage = false;
      await download();
      expect(await File(path).readAsBytes(), [1, 2, 3]);
      expect(
        requests,
        hasLength(3),
      ); // Explicit retry; no new feed or silent replay.
    },
  );

  test(
    'download validates actual bytes, removes partial files, preserves unrelated data',
    () async {
      final dir = await Directory.systemTemp.createTemp('update-test-');
      addTearDown(() => dir.delete(recursive: true));
      final history = File('${dir.path}/history.db');
      await history.writeAsString('unchanged');
      for (final bytes in [
        [1, 2, 3],
        [1, 2],
        [1, 2, 3, 4],
        [3, 2, 1],
      ]) {
        final file = File('${dir.path}/update.apk');
        final client = MockClient((request) async {
          expect(request.followRedirects, false);
          return http.Response.bytes(bytes, 200);
        });
        final operation = downloadUpdate(
          client,
          'https://updates.test',
          AppUpdate.parse(jsonEncode(manifest()), package),
          file.path,
          (_) {},
          () => false,
        );
        if (listEquals(bytes, [1, 2, 3])) {
          await operation;
          expect(await file.readAsBytes(), bytes);
          await file.delete();
        } else {
          await expectLater(operation, throwsFormatException);
          expect(await file.exists(), false);
        }
        client.close();
        expect(await history.readAsString(), 'unchanged');
      }
      final client = MockClient(
        (_) async => http.Response.bytes([1, 2, 3], 200),
      );
      final file = File('${dir.path}/cancelled.apk');
      await expectLater(
        downloadUpdate(
          client,
          'https://updates.test',
          AppUpdate.parse(jsonEncode(manifest()), package),
          file.path,
          (_) {},
          () => true,
        ),
        throwsStateError,
      );
      expect(await file.exists(), false);
    },
  );

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(updateChannel, (call) async {
          if (call.method == 'info') {
            return {
              'applicationId': package,
              'versionName': '1.1.0',
              'versionCode': 2,
              'sdk': 35,
              'pending': false,
            };
          }
          fail('Unexpected native action: ${call.method}');
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(updateChannel, null);
  });

  testWidgets(
    'manual check only; no download before consent; small screen at 200%',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: AppUpdateDialog(
              prepareInstall: () async => null,
              origin: 'https://updates.test',
              createClient: () => MockClient((request) async {
                requests++;
                expect(request.url.path, '/updates/android/latest.json');
                return http.Response(
                  jsonEncode(manifest()),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                );
              }),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 0);
      await tester.ensureVisible(find.text('Проверить обновления'));
      await tester.tap(find.text('Проверить обновления'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(find.text('Скачать и установить'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(tester.takeException(), null);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'late response after cancellation cannot offer or install update',
    (tester) async {
      final response = Completer<http.Response>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppUpdateDialog(
              prepareInstall: () async => null,
              origin: 'https://updates.test',
              createClient: () => MockClient((_) => response.future),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Проверить обновления'));
      await tester.pump();
      await tester.tap(find.text('Отменить'));
      response.complete(
        http.Response(
          jsonEncode(manifest()),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Скачать и установить'), findsNothing);
      expect(find.text('Проверить обновления'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
