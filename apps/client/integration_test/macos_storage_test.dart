import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sql;
import 'package:voicechat_probe/local_store_native.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real macOS Keychain and SQLCipher preserve data and reject lost keys',
    (tester) async {
      expect(Platform.isMacOS, isTrue);
      await vod.init();
      final name = 'macos_smoke_${DateTime.now().microsecondsSinceEpoch}';
      final keyName = 'database:$name';
      final path = '${await sql.getDatabasesPath()}/$name.secure.db';
      final plaintext = Uint8List.fromList(
        utf8.encode('disposable-encrypted-macos-fixture'),
      );
      String? key;
      try {
        var store = await openStore(name, automatic: true);
        await writeBlob(name, 'fixture', plaintext);
        expect(await readBlob(name, 'fixture'), plaintext);
        final beforeTemporary = await storeUsage(name);
        await writeP2pBlob(
          name,
          'p2p/${'a' * 32}/0/0',
          Uint8List(4 * 1024 * 1024),
        );
        expect(
          await storeUsage(name),
          greaterThan(beforeTemporary + 4 * 1024 * 1024),
        );
        await deleteP2pBlobs(name, 'a' * 32);
        expect(await storeUsage(name), lessThan(beforeTemporary + 65536));
        expect(await readBlob(name, 'fixture'), plaintext);
        key = await vault.read(key: keyName);
        expect(key, isNotNull);
        await store.close();
        await closeStore(name);
        final original = await File(path).readAsBytes();
        expect(
          utf8.decode(original, allowMalformed: true),
          isNot(contains('disposable-encrypted-macos-fixture')),
        );
        store = await openStore(name, automatic: true);
        expect(await readBlob(name, 'fixture'), plaintext);
        await store.close();
        await closeStore(name);
        final beforeFailure = await File(path).readAsBytes();
        await vault.delete(key: keyName);
        await expectLater(openStore(name, automatic: true), throwsStateError);
        expect(await File(path).readAsBytes(), beforeFailure);
        await vault.write(key: keyName, value: 'wrong-key');
        await expectLater(openStore(name, automatic: true), throwsA(anything));
        expect(await File(path).readAsBytes(), beforeFailure);
        await vault.write(key: keyName, value: key!);
        store = await openStore(name, automatic: true);
        expect(await readBlob(name, 'fixture'), plaintext);
        await store.close();
        await closeStore(name);
      } finally {
        await closeStore(name);
        await eraseStore(name);
      }
    },
  );
}
