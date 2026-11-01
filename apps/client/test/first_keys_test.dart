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
  bool signedByMaster = false;
  @override
  bool hasValidSignatureChain({
    bool verifiedOnly = true,
    Set<String>? visited,
    Set<String>? onlyValidateUserIds,
    bool verifiedByTheirMasterKey = false,
  }) => signedByMaster;
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

class PinMaster extends Fake implements CrossSigningKey {
  @override
  final String userId;
  PinMaster(this.userId);
  @override
  String get publicKey => 'master-key';
  @override
  List<String> get usage => ['master'];
  @override
  bool get isValid => true;
  @override
  bool get blocked => false;
  @override
  bool directVerified = false;
  bool signedByTrustedDevice = false;
  @override
  bool hasValidSignatureChain({
    bool verifiedOnly = true,
    Set<String>? visited,
    Set<String>? onlyValidateUserIds,
    bool verifiedByTheirMasterKey = false,
  }) {
    expect(onlyValidateUserIds, {userId});
    return signedByTrustedDevice;
  }

  @override
  Future<void> setVerified(bool value, [bool sign = true]) async =>
      directVerified = value;
}

void main() {
  test(
    'A later master signed by a trusted device authorizes its signed phone',
    () async {
      final client = PinClient();
      final first = PinDevice('@friend:local', 'A', 'first-key');
      final list = client.userDeviceKeys[first.userId] = DeviceKeysList(
        first.userId,
        client,
        deviceKeys: {'A': first},
      );
      enableFirstContactTrust(client);
      await acceptFirstKeys(client, {first.userId});
      final master = PinMaster(first.userId);
      list.crossSigningKeys[master.publicKey] = master;
      final phone = PinDevice(first.userId, 'B', 'phone-key')
        ..signedByMaster = true;
      list.deviceKeys['B'] = phone;
      await acceptFirstKeys(client, {first.userId});
      expect(
        phone.directVerified,
        false,
        reason: 'An unbound master cannot authorize a phone',
      );
      master.signedByTrustedDevice = true;
      await acceptFirstKeys(client, {first.userId});
      expect(master.directVerified, true);
      expect(phone.directVerified, true);
      final unsigned = PinDevice(first.userId, 'C', 'unsigned-key');
      list.deviceKeys['C'] = unsigned;
      await acceptFirstKeys(client, {first.userId});
      expect(unsigned.directVerified, false);
    },
  );
  test('Empty device discovery does not consume first-contact trust', () async {
    final client = PinClient();
    const user = '@new-group-member:local';
    client.userDeviceKeys[user] = DeviceKeysList(user, client);
    enableFirstContactTrust(client);
    await acceptFirstKeys(client, {user});
    expect(client.database.writes, 0);
    await client.database.storeAccountData('dev.voicechat.local.first_keys', {
      'version': 1,
      'users': {
        user: {'devices': <String, dynamic>{}, 'master': null},
      },
    });
    final device = PinDevice(user, 'PHONE', 'phone-key');
    client.userDeviceKeys[user]!.deviceKeys[device.deviceId] = device;
    await acceptFirstKeys(client, {user});
    expect(device.directVerified, true);
    expect(client.database.writes, 2);
  });
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
