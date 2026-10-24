import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/device_link.dart';
import 'first_keys_test.dart' show PinClient, PinDevice, PinDatabase;
// ignore: implementation_imports
import 'package:matrix/encryption/utils/ssss_cache.dart';

class LinkDatabase extends PinDatabase {
  SSSSCache? marker;
  @override
  Future<SSSSCache?> getSSSSCache(String type) async => marker;
  @override
  Future<void> storeSSSSCache(
    String type,
    String keyId,
    String ciphertext,
    String content,
  ) async {
    marker = SSSSCache(
      type: type,
      keyId: keyId,
      ciphertext: ciphertext,
      content: content,
    );
  }
}

class LinkClient extends PinClient {
  final _database = LinkDatabase();
  @override
  LinkDatabase get database => _database;
  @override
  String get deviceID => 'LOCAL';
  @override
  String get userID => '@me:local';
}

void main() {
  test(
    'Readiness is absent until explicitly committed to the encrypted database',
    () async {
      final client = LinkClient();
      expect(await deviceLinked(client), false);
      await markDeviceLinked(client);
      expect(await deviceLinked(client), true);
    },
  );
  test(
    'Unverified, foreign and replaced devices cannot request secrets or mark readiness',
    () async {
      final client = LinkClient();
      final device = PinDevice(client.userID, 'D', 'key');
      client.userDeviceKeys[client.userID] = DeviceKeysList(
        client.userID,
        client,
        deviceKeys: {'D': device},
      );
      await expectLater(
        receiveLinkedSecrets(client, device),
        throwsA(anything),
      );
      final foreign = PinDevice('@other:local', 'D', 'key')
        ..directVerified = true;
      await expectLater(
        receiveLinkedSecrets(client, foreign),
        throwsA(anything),
      );
      final replaced = PinDevice(client.userID, 'D', 'old-key')
        ..directVerified = true;
      device.directVerified = true;
      await expectLater(
        receiveLinkedSecrets(client, replaced),
        throwsA(anything),
      );
      expect(await deviceLinked(client), false);
    },
  );
}
