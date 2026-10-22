import 'dart:convert';
import 'package:matrix/matrix.dart';
import 'user_action_error.dart';

final _enabled = Expando<bool>();
final _writes = Expando<Future<void>>();
const _storage = 'dev.voicechat.local.first_keys';
void enableFirstContactTrust(Client client) => _enabled[client] = true;
Future<void> acceptFirstKeys(Client client, Set<String> users) {
  if (_enabled[client] != true) return Future.value();
  return _writes[client] = (_writes[client] ?? Future.value())
      .catchError((Object _) {})
      .then((_) => _accept(client, users));
}

Future<Map<String, dynamic>> _load(Client client) async {
  final value = (await client.database.getAccountData())[_storage]?.content;
  if (value == null) return {'version': 1, 'users': <String, dynamic>{}};
  if (value['version'] != 1 || value['users'] is! Map) {
    throw const FormatException('Invalid pinned keys');
  }
  return jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}

String _fingerprint(DeviceKeys device) =>
    '${device.ed25519Key}/${device.curve25519Key}';
Future<void> _accept(Client client, Set<String> users) async {
  final pins = await _load(client);
  final pinnedUsers = pins['users'] as Map;
  final approve = <DeviceKeys>[];
  final masters = <CrossSigningKey>[];
  for (final user in users) {
    final list = client.userDeviceKeys[user];
    if (list == null) throw StateError('Keys unavailable');
    final devices = list.deviceKeys.values
        .where((d) => !d.blocked && d.isValid)
        .toList();
    final master = list.crossSigningKeys.values
        .where((k) => k.usage.contains('master') && k.isValid && !k.blocked)
        .firstOrNull;
    final first = !pinnedUsers.containsKey(user);
    final alreadyTrusted = devices.any((d) => d.directVerified);
    final pin =
        pinnedUsers[user] ??
        <String, dynamic>{
          'devices': <String, dynamic>{},
          'master': alreadyTrusted && master?.directVerified != true
              ? null
              : master?.publicKey,
        };
    if (pin is! Map || pin['devices'] is! Map) {
      throw const FormatException('Invalid user pins');
    }
    final known = pin['devices'] as Map;
    for (final device in devices) {
      final previous = known[device.deviceId];
      if (previous != null && previous != _fingerprint(device)) {
        throw UserActionError(
          'Ключ устройства $user изменился. Переписка приостановлена до независимой проверки.',
        );
      }
    }
    if (master != null && pin['master'] == master.publicKey) {
      masters.add(master);
    }
    for (final device in devices) {
      if (known[device.deviceId] == _fingerprint(device) ||
          device.directVerified ||
          first && !alreadyTrusted) {
        known[device.deviceId] = _fingerprint(device);
        approve.add(device);
      }
    }
    pinnedUsers[user] = pin;
  }
  // Pin durably before granting trust; a failed write must not silently accept new keys.
  await client.database.storeAccountData(_storage, pins);
  for (final master in masters) {
    await master.setVerified(true, false);
  }
  for (final user in users) {
    final pin = pinnedUsers[user] as Map;
    final master = client.userDeviceKeys[user]!.crossSigningKeys.values
        .where(
          (k) => k.usage.contains('master') && k.publicKey == pin['master'],
        )
        .firstOrNull;
    for (final device in client.userDeviceKeys[user]!.deviceKeys.values) {
      if (!device.blocked &&
          device.isValid &&
          !approve.contains(device) &&
          master != null &&
          device.hasValidSignatureChain(onlyValidateUserIds: {user})) {
        (pin['devices'] as Map)[device.deviceId] = _fingerprint(device);
        approve.add(device);
      }
    }
  }
  await client.database.storeAccountData(_storage, pins);
  for (final device in approve) {
    if (!device.directVerified) await device.setVerified(true, false);
  }
}

Future<void> pinManuallyVerifiedDevice(
  Client client,
  DeviceKeys device, {
  CrossSigningKey? master,
}) async {
  if (master != null &&
      (master.userId != device.userId ||
          !master.usage.contains('master') ||
          !master.isValid ||
          master.blocked)) {
    throw StateError('Invalid independently verified master key');
  }
  if (_enabled[client] != true) return;
  await (_writes[client] = (_writes[client] ?? Future.value())
      .catchError((Object _) {})
      .then((_) async {
        final pins = await _load(client);
        final users = pins['users'] as Map;
        final pin =
            users[device.userId] ??
            <String, dynamic>{'devices': <String, dynamic>{}};
        (pin['devices'] as Map)[device.deviceId] = _fingerprint(device);
        (pin.putIfAbsent('verified', () => <String, dynamic>{})
            as Map)[device.deviceId] = _fingerprint(
          device,
        );
        if (master != null) pin['master'] = master.publicKey;
        users[device.userId] = pin;
        await client.database.storeAccountData(_storage, pins);
      }));
}

Future<Set<DeviceKeys>> independentlyVerifiedDevices(
  Client client,
  Iterable<DeviceKeys> devices,
) async {
  final pins = (await _load(client))['users'] as Map;
  return devices
      .where(
        (device) =>
            pins[device.userId]?['verified']?[device.deviceId] ==
            _fingerprint(device),
      )
      .toSet();
}
