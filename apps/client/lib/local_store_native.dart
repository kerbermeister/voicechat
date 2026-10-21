import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sql;

String? readTabAccount() => null;
void writeTabAccount(String? value) {}

const vault = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: false),
);

Future<MatrixSdkDatabase> openStore(
  String name, {
  String? passphrase,
  bool remember = false,
}) async {
  final root = await sql.getDatabasesPath();
  if (await sql.databaseExists('$root/$name.db')) {
    // Never silently abandon or delete an unencrypted prototype history.
    throw StateError(
      'Legacy plaintext profile: save recovery key before clearing app data',
    );
  }
  final path = '$root/$name.secure.db';
  final keyName = 'database:$name';
  var password = await vault.read(key: keyName);
  if (password == null) {
    if (await sql.databaseExists(path)) {
      throw StateError('Database key unavailable; recovery is required');
    }
    final random = Random.secure();
    password = base64Encode(List.generate(32, (_) => random.nextInt(256)));
    await vault.write(key: keyName, value: password);
  }
  if (await sql.databaseExists(path)) {
    // Android's writable SQLite opener may recreate a file it cannot decrypt.
    final check = await sql.openDatabase(
      path,
      password: password,
      readOnly: true,
      singleInstance: false,
    );
    try {
      await check.rawQuery('SELECT name FROM sqlite_master');
    } finally {
      await check.close();
    }
  }
  final database = await sql.openDatabase(path, password: password);
  try {
    final cipher = await database.rawQuery('PRAGMA cipher_version');
    if (cipher.isEmpty) throw StateError('SQLCipher unavailable');
    return await MatrixSdkDatabase.init(
      name,
      database: database,
      sqfliteFactory: sql.databaseFactory,
    );
  } catch (_) {
    await database.close();
    rethrow;
  }
}

Future<void> eraseStore(String name) async {
  await vault.delete(key: 'database:$name');
  await sql.deleteDatabase('${await sql.getDatabasesPath()}/$name.secure.db');
}

Future<void> closeStore(String name) async {}
