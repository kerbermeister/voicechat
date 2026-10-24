import 'dart:async';
import 'package:matrix/matrix.dart';
import 'user_action_error.dart';

const deviceLinkMarker = 'dev.voicechat.local.device_link';

// Keep readiness in the local secret cache, never in server-synced account data.
Future<bool> deviceLinked(Client client) async {
  final marker = await client.database.getSSSSCache(deviceLinkMarker);
  return marker?.keyId == client.deviceID && marker?.content == client.userID;
}

Future<void> markDeviceLinked(Client client) => client.database.storeSSSSCache(
  deviceLinkMarker,
  client.deviceID!,
  '',
  client.userID!,
);

/// Request only from the exact device whose SAS proof the user just approved.
Future<void> receiveLinkedSecrets(Client client, DeviceKeys device) async {
  final current =
      client.userDeviceKeys[client.userID]?.deviceKeys[device.deviceId];
  if (device.userId != client.userID ||
      current == null ||
      !current.isValid ||
      !current.directVerified ||
      current.blocked ||
      current.ed25519Key != device.ed25519Key ||
      current.curve25519Key != device.curve25519Key) {
    throw UserActionError('Устройство не подтверждено. Ключи не запрошены.');
  }
  final ssss = client.encryption!.ssss;
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  await ssss.maybeRequestAll([current]);
  while (true) {
    final secrets = await Future.wait([
      ssss.getCached(EventTypes.CrossSigningSelfSigning),
      ssss.getCached(EventTypes.CrossSigningUserSigning),
      ssss.getCached(EventTypes.MegolmBackup),
    ]);
    if (secrets.every((secret) => secret != null)) break;
    if (DateTime.now().isAfter(deadline)) {
      throw UserActionError(
        'Ключи пока не получены. Оставьте первое устройство открытым и повторите подключение.',
      );
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  // Verifies backup public key before decrypting its contents.
  final latest =
      client.userDeviceKeys[client.userID]?.deviceKeys[device.deviceId];
  if (latest == null ||
      latest.blocked ||
      !latest.directVerified ||
      latest.ed25519Key != device.ed25519Key ||
      latest.curve25519Key != device.curve25519Key) {
    throw UserActionError(
      'Устройство изменилось во время подключения. Повторите проверку.',
    );
  }
  await client.encryption!.crossSigning.sign([
    client.userDeviceKeys[client.userID]!.deviceKeys[client.deviceID]!,
  ]);
  await client.encryption!.keyManager.loadAllKeys();
  await markDeviceLinked(client);
}
