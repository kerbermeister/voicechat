import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/first_keys.dart';
import 'chat_actions_test.dart' show OutboxDatabase;

class PinClient implements Client {
  @override
  final PinDatabase database = PinDatabase();
  @override
  final userDeviceKeys = <String, DeviceKeysList>{};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class PinDatabase extends OutboxDatabase {
  int writes = 0;
  @override
  Future<void> storeAccountData(
    String type,
    Map<String, Object?> content,
  ) async {
    await super.storeAccountData(type, content);
    writes++;
  }
}

class PinDevice implements DeviceKeys {
  @override
  final String userId;
  @override
  final String deviceId;
  @override
  final String ed25519Key;
  @override
  String get curve25519Key => 'curve-$ed25519Key';
  @override
  bool directVerified = false;
  @override
  bool get blocked => false;
  @override
  bool get isValid => true;
  PinDevice(this.userId, this.deviceId, this.ed25519Key);
  @override
  Future<void> setVerified(bool value, [bool sign = true]) async {
    directVerified = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'TOFU pins first keys durably, refuses replacement and does not auto-trust unsigned new devices',
    () async {
      final client = PinClient();
      final first = PinDevice('@friend:local', 'A', 'first-key');
      client.userDeviceKeys[first.userId] = DeviceKeysList(
        first.userId,
        client,
        deviceKeys: {'A': first},
      );
      await acceptFirstKeys(client, {first.userId});
      expect(
        first.directVerified,
        false,
        reason: 'Strict laboratory clients must remain strict',
      );
      enableFirstContactTrust(client);
      client.database.failWrite = true;
      await expectLater(
        acceptFirstKeys(client, {first.userId}),
        throwsStateError,
      );
      expect(first.directVerified, false);
      client.database.failWrite = false;
      await acceptFirstKeys(client, {first.userId});
      expect(first.directVerified, true);
      final writes = client.database.writes;
      first.directVerified = false;
      await acceptFirstKeys(client, {first.userId});
      expect(
        first.directVerified,
        true,
        reason: 'Previously persisted pins still authorize the exact key',
      );
      expect(
        client.database.writes,
        writes,
        reason: 'Unchanged pins must not rewrite the encrypted vault',
      );
      final second = PinDevice(first.userId, 'B', 'unsigned-key');
      client.userDeviceKeys[first.userId]!.deviceKeys['B'] = second;
      await acceptFirstKeys(client, {first.userId});
      expect(second.directVerified, false);
      final replacement = PinDevice(first.userId, 'A', 'replacement-key');
      client.userDeviceKeys[first.userId]!.deviceKeys['A'] = replacement;
      await expectLater(
        acceptFirstKeys(client, {first.userId}),
        throwsA(anything),
      );
      expect(replacement.directVerified, false);
      await pinManuallyVerifiedDevice(client, replacement);
      await acceptFirstKeys(client, {first.userId});
      expect(replacement.directVerified, true);
    },
  );
}
