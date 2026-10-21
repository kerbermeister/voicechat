import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:matrix/matrix.dart';
import 'user_action_error.dart';

@JS('voicechatVault.usage')
external JSPromise<JSNumber> _usage(JSString name);
Future<int> storeUsage(String name) async =>
    (await _usage(name.toJS).toDart).toDartInt;
Future<void> compactStore(String name) async {}

@JS('voicechatVault.writeBlob')
external JSPromise<JSAny?> _writeBlob(
  JSString name,
  JSString id,
  JSUint8Array bytes,
);
@JS('voicechatVault.readBlob')
external JSPromise<JSUint8Array?> _readBlob(JSString name, JSString id);
@JS('voicechatVault.deleteBlob')
external JSPromise<JSAny?> _deleteBlob(JSString name, JSString id);
Future<void> writeBlob(String name, String id, Uint8List bytes) async {
  await _writeBlob(name.toJS, id.toJS, bytes.toJS).toDart;
}

Future<Uint8List?> readBlob(String name, String id) async =>
    (await _readBlob(name.toJS, id.toJS).toDart)?.toDart;
Future<void> deleteBlob(String name, String id) async {
  await _deleteBlob(name.toJS, id.toJS).toDart;
}

@JS('voicechatVault.readAccount')
external JSString? _readAccount();
@JS('voicechatVault.writeAccount')
external void _writeAccount(JSString? value);

String? readTabAccount() => _readAccount()?.toDart;
void writeTabAccount(String? value) => _writeAccount(value?.toJS);

@JS('voicechatVault.open')
external JSPromise<JSAny?> _open(
  JSString name,
  JSString? password,
  JSBoolean remember,
);
@JS('voicechatVault.close')
external JSPromise<JSAny?> _close(JSString name);
@JS('voicechatVault.erase')
external JSPromise<JSAny?> _erase(JSString name);
@JS('voicechatVault.encrypt')
external JSPromise<JSString> _encrypt(
  JSString name,
  JSString store,
  JSString key,
  JSString value,
);
@JS('voicechatVault.decrypt')
external JSPromise<JSString> _decrypt(
  JSString name,
  JSString store,
  JSString key,
  JSString value,
);

class WebVaultCodec implements DatabaseCodec {
  final String name;
  WebVaultCodec(this.name);
  @override
  Future<Object?> encode(String store, String key, Object? value) async =>
      (await _encrypt(
        name.toJS,
        store.toJS,
        key.toJS,
        jsonEncode(value).toJS,
      ).toDart).toDart;
  @override
  Future<Object?> decode(String store, String key, Object? value) async {
    try {
      if (value is! String) {
        throw StateError('Unencrypted vault record refused');
      }
      return jsonDecode(
        (await _decrypt(
          name.toJS,
          store.toJS,
          key.toJS,
          value.toJS,
        ).toDart).toDart,
      );
    } catch (_) {
      throw const DatabaseIntegrityException();
    }
  }
}

Future<MatrixSdkDatabase> openStore(
  String name, {
  String? passphrase,
  bool remember = false,
}) async {
  try {
    await _open(name.toJS, passphrase?.toJS, remember.toJS).toDart;
  } catch (_) {
    throw UserActionError(
      'Не удалось открыть веб-хранилище. Проверьте локальную фразу (от 12 символов), закройте другие вкладки этого профиля. Старые незашифрованные профили требуют восстановления. Данные не сброшены.',
    );
  }
  final database = MatrixSdkDatabase.buildWithoutOpen(
    '$name.encrypted',
    indexedDbCodec: WebVaultCodec(name),
  );
  try {
    await database.open();
    return database;
  } catch (_) {
    try {
      await database.close();
    } catch (_) {
      /* Opening may fail before a handle exists. */
    }
    await closeStore(name);
    rethrow;
  }
}

Future<void> closeStore(String name) async {
  await _close(name.toJS).toDart;
}

Future<void> eraseStore(String name) async {
  await _erase(name.toJS).toDart;
}
