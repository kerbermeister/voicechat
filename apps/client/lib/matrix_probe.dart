import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'local_store.dart';
import 'transport.dart';
import 'user_action_error.dart';

/// Matrix session backed by the platform encrypted store.
class MatrixProbe {
  static Future<void>? _cryptoInit;
  final Client client;
  MatrixProbe(this.client);

  static Future<MatrixProbe> open(String profile, {String? passphrase}) async {
    _cryptoInit ??= vod.init();
    await _cryptoInit;
    final name = 'voicechat_probe_${Uri.encodeComponent(profile)}';
    final db = await openStore(name, passphrase: passphrase);
    final client = Client(
      name,
      database: db,
      shareKeysWith: ShareKeysWith.directlyVerifiedOnly,
      logLevel: Level.error,
    );
    try {
      await client.init();
      return MatrixProbe(client);
    } catch (_) {
      try {
        await client.dispose();
      } finally {
        await closeStore(name);
      }
      rethrow;
    }
  }

  Future<void> login(String server, String username, String password) async {
    if (!client.isLogged()) {
      await client.checkHomeserver(
        secureEndpoint(server),
        checkWellKnown: false,
      );
      await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: username),
        password: password,
        initialDeviceDisplayName: kIsWeb ? 'Web probe' : 'Android probe',
      );
    }
    await client.firstSyncReceived;
    if (!client.encryptionEnabled) throw StateError('E2EE unavailable');
  }

  Future<T> authenticate<T>(
    String password,
    Future<T> Function() action,
  ) async {
    final attempted = <UiaRequest>{};
    final subscription = client.onUiaRequest.stream.listen((request) {
      if (request.state != UiaRequestState.waitForUser) return;
      if (!attempted.add(request)) {
        request.cancel(Exception('Authentication failed'));
        return;
      }
      if (request.nextStages.contains(AuthenticationTypes.password)) {
        unawaited(
          request.completeStage(
            AuthenticationPassword(
              session: request.session,
              password: password,
              identifier: AuthenticationUserIdentifier(user: client.userID!),
            ),
          ),
        );
      } else {
        request.cancel(Exception('Unsupported authentication stage'));
      }
    });
    try {
      return await action();
    } finally {
      await subscription.cancel();
    }
  }

  Future<String> initializeRecovery(String password) async {
    final state = await client.getCryptoIdentityState();
    if (state.initialized) {
      throw StateError(
        'Identity already exists. Restore it; do not overwrite.',
      );
    }
    return authenticate(password, client.initCryptoIdentity);
  }

  Future<void> restore(String recoveryKey) async {
    await client.restoreCryptoIdentity(recoveryKey.trim());
    await client.encryption!.keyManager.loadAllKeys();
  }

  Future<String> createRoom(List<String> invitees) => client.createRoom(
    name: 'Тёплый круг · прототип',
    preset: CreateRoomPreset.privateChat,
    invite: invitees,
    initialState: [
      StateEvent(
        type: EventTypes.Encryption,
        stateKey: '',
        content: {'algorithm': 'm.megolm.v1.aes-sha2'},
      ),
      StateEvent(
        type: 'm.room.history_visibility',
        stateKey: '',
        content: {'history_visibility': 'joined'},
      ),
    ],
  );

  Future<Room> room(String id) async {
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(until)) {
      final room = client.getRoomById(id);
      if (room != null && room.membership == Membership.join) {
        if (!room.encrypted) throw StateError('Unencrypted room refused');
        return room;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw TimeoutException('Room sync timed out');
  }

  static Future<String> sendText(Room room, String text) async {
    if (!room.encrypted) throw StateError('E2EE required');
    await authorizedDevices(room).timeout(const Duration(seconds: 5));
    // shortcut: rotate every send; optimize when SDK handles device revocation.
    await room.client.encryption!.keyManager.clearOrUseOutboundGroupSession(
      room.id,
      wipe: true,
    );
    final id = await room.sendTextEvent(text, parseCommands: false);
    if (id == null) throw StateError('Message was not sent');
    return id;
  }

  Future<void> revokeDevice(String deviceId, String password) async {
    if (deviceId == client.deviceID) {
      throw StateError('Use logout for this device');
    }
    await authenticate(
      password,
      () => client.uiaRequestBackground(
        (auth) => client.deleteDevice(deviceId, auth: auth),
      ),
    );
    if ((await client.getDevices())!.any((d) => d.deviceId == deviceId)) {
      throw StateError('Device revocation was not confirmed');
    }
  }

  Future<void> backup() =>
      client.encryption!.keyManager.uploadInboundGroupSessions();

  Future<void> logout() async {
    await backup();
    // Client.logout clears local history even when the server request fails.
    await MatrixApi(
      homeserver: client.homeserver,
      accessToken: client.accessToken,
      httpClient: client.httpClient,
    ).logout();
    await client.clear(reason: SessionClearReason.logout);
    await close();
    await eraseStore(client.clientName);
  }

  Future<void> close() async {
    try {
      await client.dispose();
    } finally {
      await closeStore(client.clientName);
    }
  }
}

/// Refresh authorization from the server, never infer revocation from a cache.
Future<List<DeviceKeys>> authorizedDevices(Room room) async {
  await room.client.getTokenOwner();
  await room.requestParticipants(
    const [
      Membership.join,
      Membership.invite,
      Membership.leave,
      Membership.ban,
      Membership.knock,
    ],
    true,
    true,
    true,
  );
  final members = await room.client.getJoinedMembersByRoom(room.id);
  if (members == null || !members.containsKey(room.client.userID)) {
    throw StateError('Room access revoked');
  }
  await refreshDevices(room.client, members.keys.toSet());
  final devices = members.keys.expand(
    (user) => room.client.userDeviceKeys[user]!.deviceKeys.values,
  );
  if (devices.any((device) => !device.blocked && !device.directVerified)) {
    throw UserActionError(
      'Сначала откройте «Проверить устройства» и сверьте отпечатки участников.',
    );
  }
  return members.keys
      .expand(
        (user) =>
            room.client.userDeviceKeys[user]?.deviceKeys.values ??
            <DeviceKeys>[],
      )
      .where((device) => device.encryptToDevice && !device.blocked)
      .toList();
}

Future<void> refreshDevices(Client client, Set<String> users) async {
  for (final user in users) {
    client.userDeviceKeys[user]?.outdated = true;
  }
  await client.updateUserDeviceKeys(additionalUsers: users);
  if (users.any((user) => client.userDeviceKeys[user]?.outdated != false)) {
    throw StateError('Device authorization refresh failed');
  }
}

Future<void> verifyDevice(
  Client client,
  String userId,
  String deviceId,
  String fingerprint,
) async {
  await refreshDevices(client, {userId});
  final device = client.userDeviceKeys[userId]?.deviceKeys[deviceId];
  final entered = fingerprint.replaceAll(RegExp(r'\s'), '');
  if (device == null ||
      device.blocked ||
      entered.isEmpty ||
      entered != device.ed25519Key) {
    throw UserActionError(
      'Отпечаток не совпал или устройство недоступно. Доверие не изменено.',
    );
  }
  await device.setVerified(true, false);
}
