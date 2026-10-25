// Test-only entrypoint. Never publish this APK or point production metadata at it.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as loader;
import 'package:vodozemac/vodozemac.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' show sha256;
import 'package:voicechat_probe/app_update_dialog.dart';
import 'package:voicechat_probe/local_store_native.dart';

class FixtureTransport extends http.BaseClient {
  final _client = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.host != 'fixture.invalid') {
      throw StateError('Unexpected fixture host');
    }
    return _client.send(
      http.Request(
        request.method,
        Uri.parse('http://127.0.0.1:8766${request.url.path}'),
      )..followRedirects = false,
    );
  }

  @override
  void close() => _client.close();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!const bool.fromEnvironment('UPDATE_FIXTURE')) {
    throw StateError('Test fixture only');
  }
  await loader.init();
  final info = (await updateChannel.invokeMapMethod<String, dynamic>('info'))!;
  const name = 'voicechat_update_fixture';
  final database = await openStore(name);
  final code = info['versionCode'] as int;
  final existing =
      (await database.getAccountData())['dev.voicechat.local.update-fixture']
          ?.content;
  if (existing == null && code != 100) {
    throw StateError('Original profile lost');
  }
  if (existing == null) {
    final key = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await vault.write(key: 'update-test-pickle', value: base64Encode(key));
    final outbound = crypto.GroupSession();
    final inbound = crypto.InboundGroupSession(outbound.sessionKey);
    final account = crypto.Account();
    await database.storeClient(
      homeserverUrl: 'https://fixture.invalid',
      token: 'synthetic-token',
      userId: '@fixture:test',
      deviceId: 'UNCHANGED_DEVICE',
    );
    await database.storeAccountData('dev.voicechat.local.update-fixture', {
      'inbound': inbound.toPickleEncrypted(key),
      'account': account.toPickleEncrypted(key),
      'fingerprint': account.ed25519Key.toBase64(),
      'ciphertext': outbound.encrypt('E2EE before update'),
      'databaseKeyHash': sha256
          .convert(utf8.encode((await vault.read(key: 'database:$name'))!))
          .toString(),
    });
    await database.storeAccountData('dev.voicechat.local.drafts', {
      '!fixture:test': 'Draft before update',
    });
    await writeBlob(
      name,
      'attachment',
      Uint8List.fromList(List.generate(4096, (i) => i % 251)),
    );
  }
  final saved =
      (await database.getAccountData())['dev.voicechat.local.update-fixture']!
          .content;
  final pickleKey = base64Decode(
    (await vault.read(key: 'update-test-pickle'))!,
  );
  final inbound = crypto.InboundGroupSession.fromPickleEncrypted(
    pickle: saved['inbound'] as String,
    pickleKey: pickleKey,
  );
  final account = crypto.Account.fromPickleEncrypted(
    pickle: saved['account'] as String,
    pickleKey: pickleKey,
  );
  final client = (await database.getClient(name))!;
  final checks = {
    'identity':
        client['user_id'] == '@fixture:test' &&
        client['device_id'] == 'UNCHANGED_DEVICE',
    'token': client['token'] == 'synthetic-token',
    'fingerprint': account.ed25519Key.toBase64() == saved['fingerprint'],
    'e2ee':
        inbound.decrypt(saved['ciphertext'] as String).plaintext ==
        'E2EE before update',
    'keystore':
        sha256
            .convert(utf8.encode((await vault.read(key: 'database:$name'))!))
            .toString() ==
        saved['databaseKeyHash'],
    'blob':
        base64Encode((await readBlob(name, 'attachment'))!) ==
        base64Encode(List.generate(4096, (i) => i % 251)),
    'draft':
        (await database.getAccountData())['dev.voicechat.local.drafts']
            ?.content['!fixture:test'] ==
        'Draft before update',
  };
  await database.close();
  if (checks.values.any((ok) => !ok)) {
    throw StateError('Data preservation failed: $checks');
  }
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Builder(
            builder: (context) => Column(
              children: [
                Text(
                  'FIXTURE $code PASS: identity token fingerprint e2ee keystore blob draft',
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AppUpdateDialog(
                      prepareInstall: () async => null,
                      origin: 'https://fixture.invalid',
                      createClient: FixtureTransport.new,
                    ),
                  ),
                  child: const Text('О приложении'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
