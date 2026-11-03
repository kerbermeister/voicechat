// Real native key providers; only the selected installation reply is delayed
// or rejected. No accounts, capture, files, playback or network are opened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final failure in ['false', 'exception', 'pending']) {
    testWidgets(
      'Native key installation preserves confirmed slot: $failure',
      (tester) async {
        await tester.runAsync(() async {
          final provider = await lk.BaseKeyProvider.create(sharedKey: false);
          const channel = MethodChannel('FlutterWebRTC.Method');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          final reached = Completer<void>(), release = Completer<void>();
          final nextKey = Uint8List.fromList(List.filled(32, 123));
          var injected = false;
          Future<void>? pending;
          try {
            await provider.setRawKey(Uint8List(32), participantId: 'alice');
            messenger.setMockMethodCallHandler(channel, (call) async {
              final arguments = call.arguments as Map? ?? {};
              final selected =
                  !injected &&
                  call.method == 'keyProviderSetKey' &&
                  arguments['keyProviderId'] == provider.keyProvider.id &&
                  arguments['keyIndex'] == 1;
              if (selected) {
                injected = true;
                if (failure == 'false') return {'result': false};
                if (failure == 'exception') {
                  throw PlatformException(code: 'synthetic_key_failure');
                }
              }
              final bytes = await messenger.delegate.send(
                channel.name,
                channel.codec.encodeMethodCall(call),
              );
              if (bytes == null) throw MissingPluginException('Native WebRTC');
              final reply = channel.codec.decodeEnvelope(bytes);
              if (selected && failure == 'pending') {
                reached.complete();
                await release.future;
              }
              return reply;
            });
            pending = provider.setRawKey(
              nextKey,
              participantId: 'alice',
              keyIndex: 1,
            );
            if (failure == 'pending') {
              await reached.future.timeout(const Duration(seconds: 5));
              expect(provider.getLatestIndex('alice'), 0);
              release.complete();
              await pending;
            } else {
              await expectLater(pending, throwsA(anything));
              expect(provider.getLatestIndex('alice'), 0);
              await provider.setRawKey(
                nextKey,
                participantId: 'alice',
                keyIndex: 1,
              );
            }
            expect(injected, isTrue);
            expect(provider.getLatestIndex('alice'), 1);
            expect(await provider.exportKey('alice', 1), nextKey);
            // ignore: avoid_print
            print(
              'NATIVE_KEY_INSTALLATION_PROOF ${jsonEncode({'case': failure, 'confirmed_slot_preserved': true, 'retry_or_delayed_confirmation_succeeded': true, 'native_export_matches': true, 'media_opened': false})}',
            );
          } finally {
            if (!release.isCompleted) release.complete();
            try {
              await pending;
            } catch (_) {}
            messenger.setMockMethodCallHandler(channel, null);
            await provider.keyProvider.dispose();
          }
        });
      },
      skip:
          !(Platform.isMacOS || Platform.isAndroid) ||
          !const bool.fromEnvironment('HARDWARE_CALL_TEST'),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
