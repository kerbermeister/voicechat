import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart' as plain;
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;
import 'package:voicechat_probe/local_store_native.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'SQLCipher persists, rejects missing/wrong keys, preserves legacy data',
    (_) async {
      final name = 'vault_test_${DateTime.now().microsecondsSinceEpoch}';
      final root = await cipher.getDatabasesPath();
      final path = '$root/$name.secure.db';
      final keyName = 'database:$name';
      const marker = 'PRIVATE_TOKEN_NEVER_PLAINTEXT';
      final db = await openStore(name);
      await db.storeClient(
        homeserverUrl: 'https://example.invalid',
        token: marker,
        userId: '@test:example.invalid',
        deviceId: 'TEST',
      );
      await db.close();
      final bytes = await File(path).readAsBytes();
      expect(utf8.decode(bytes, allowMalformed: true), isNot(contains(marker)));
      expect(
        utf8.decode(bytes.take(16).toList(), allowMalformed: true),
        isNot(startsWith('SQLite format')),
      );
      final copy = await File(path).copy('$path.unreadable');
      await expectLater(() async {
        final unreadable = await plain.openDatabase(
          copy.path,
          readOnly: true,
          singleInstance: false,
        );
        try {
          await unreadable.rawQuery('SELECT * FROM sqlite_master');
        } finally {
          await unreadable.close();
        }
      }(), throwsA(anything));
      await expectLater(() async {
        final unreadable = await cipher.openDatabase(
          copy.path,
          readOnly: true,
          password: 'wrong',
          singleInstance: false,
        );
        try {
          await unreadable.rawQuery('SELECT * FROM sqlite_master');
        } finally {
          await unreadable.close();
        }
      }(), throwsA(anything));
      await copy.delete();
      final reopened = await openStore(name);
      expect((await reopened.getClient(name))!['token'], marker);
      await reopened.close();
      final key = await vault.read(key: keyName);
      await vault.write(key: keyName, value: 'incorrect-stored-key');
      await expectLater(openStore(name), throwsA(anything));
      expect(await File(path).readAsBytes(), bytes);
      await vault.delete(key: keyName);
      await expectLater(openStore(name), throwsStateError);
      expect(await vault.read(key: keyName), isNull);
      expect(await File(path).readAsBytes(), bytes);
      await vault.write(key: keyName, value: key!);
      final restored = await openStore(name);
      expect((await restored.getClient(name))!['token'], marker);
      await restored.close();
      final legacy = await plain.openDatabase('$root/$name.db');
      await legacy.execute('CREATE TABLE keep_me (value TEXT)');
      await legacy.close();
      await expectLater(openStore(name), throwsStateError);
      expect(await plain.databaseExists('$root/$name.db'), true);
      await plain.deleteDatabase('$root/$name.db');
      await eraseStore(name);
      expect(await cipher.databaseExists(path), false);
      expect(await vault.read(key: keyName), isNull);
    },
  );
}
