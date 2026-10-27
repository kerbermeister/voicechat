import 'device_added.dart';
import 'personal_room.dart';
import 'device_name.dart';
import 'dart:async';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'local_store.dart';
import 'transport.dart';
import 'user_action_error.dart';
import 'first_keys.dart';
import 'contact_service.dart';

/// Matrix session backed by the platform encrypted store.
class MatrixProbe {
  static Future<void>? _cryptoInit;
  final Client client;
  MatrixProbe(this.client);

  static Future<MatrixProbe> open(
    String profile, {
    String? passphrase,
    bool remember = false,
    bool automatic = false,
  }) async {
    _cryptoInit ??= vod.init();
    await _cryptoInit;
    final name = 'voicechat_probe_${Uri.encodeComponent(profile)}';
    final db = await openStore(
      name,
      passphrase: passphrase,
      remember: remember,
      automatic: automatic,
    );
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
    DateTime? addedAt;
    if (client.isLogged()) {
      final requested = username.trim();
      final localpart = client.userID!.split(':').first.substring(1);
      if ((requested != client.userID && requested != localpart) ||
          client.homeserver!.origin != secureEndpoint(server).origin) {
        throw UserActionError(
          'Этот локальный профиль уже открыт для ${client.userID}. Для другого аккаунта укажите другое имя профиля.',
        );
      }
    } else {
      await client.checkHomeserver(
        secureEndpoint(server),
        checkWellKnown: false,
      );
      await client.login(
        LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: username),
        password: password,
        initialDeviceDisplayName: await currentDeviceName(),
      );
      addedAt = DateTime.now();
    }
    await client.firstSyncReceived;
    if (addedAt != null) await recordDeviceAdded(client, addedAt);
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
    await requireHistoryBackup();
    await client.restoreCryptoIdentity(recoveryKey.trim());
    await client.encryption!.keyManager.loadAllKeys();
  }

  Future<void> requireHistoryBackup() async {
    try {
      await client.getRoomKeysVersionCurrent();
    } on MatrixException catch (error) {
      if (error.error != MatrixError.M_NOT_FOUND) rethrow;
      throw UserActionError(
        'На сервере нет резервной копии ключей этого аккаунта. '
        'Для старой истории нужно устройство, на котором она открывалась. '
        'Новый ключ восстановления не расшифрует старые сообщения без их ключей.',
      );
    }
  }

  Future<String> startDirectChat(String userId) async {
    final id = await client.startDirectChat(
      userId,
      enableEncryption: true,
      preset: CreateRoomPreset.privateChat,
      initialState: [
        StateEvent(
          type: 'dev.voicechat.kind',
          stateKey: '',
          content: {'kind': 'direct', 'owner': client.userID, 'peer': userId},
        ),
        StateEvent(
          type: 'm.room.history_visibility',
          stateKey: '',
          content: {'history_visibility': 'invited'},
        ),
      ],
    );
    // The room can sync before m.direct; do not expose it as a group or omit the invited peer's keys.
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (client.getRoomById(id)?.directChatMatrixID != userId) {
      if (DateTime.now().isAfter(until)) {
        throw TimeoutException('Direct chat metadata sync timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return id;
  }

  Future<String> createRoom(
    List<String> invitees, {
    String name = 'Тёплый круг',
    Uri? avatar,
    bool personal = false,
  }) {
    if (personal && invitees.isNotEmpty) {
      throw ArgumentError('Personal rooms cannot have invitees');
    }
    return client.createRoom(
      creationContent: personal
          ? {'type': personalRoomType, 'm.federate': false}
          : null,
      name: name,
      powerLevelContentOverride: {'invite': 50, 'kick': 50, 'ban': 50},
      preset: CreateRoomPreset.privateChat,
      invite: invitees,
      initialState: [
        if (avatar != null)
          StateEvent(
            type: EventTypes.RoomAvatar,
            stateKey: '',
            content: {'url': avatar.toString()},
          ),
        StateEvent(
          type: EventTypes.Encryption,
          stateKey: '',
          content: {'algorithm': 'm.megolm.v1.aes-sha2'},
        ),
        StateEvent(
          type: 'm.room.history_visibility',
          stateKey: '',
          content: {'history_visibility': personal ? 'joined' : 'shared'},
        ),
      ],
    );
  }

  Future<Room> room(String id) async {
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(until)) {
      final room = client.getRoomById(id);
      if (room != null &&
          room.membership == Membership.join &&
          room.encrypted) {
        return room;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw TimeoutException('Encrypted room sync timed out');
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

  Future<bool> backup() async {
    final manager = client.encryption!.keyManager;
    if (!await manager.isCached()) return false;
    await requireHistoryBackup();
    await manager.uploadInboundGroupSessions();
    // The SDK catches upload errors internally; remaining keys must not be reported as backed up.
    if ((await client.database.getInboundGroupSessionsToUpload()).isNotEmpty) {
      throw UserActionError(
        'Не все ключи сохранены в резервной копии. Локальные ключи сохранены; повторите попытку позже.',
      );
    }
    return true;
  }

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

class CallAccessChanged implements Exception {}

bool callAccessDenied(Object error) =>
    error is CallAccessChanged ||
    error is UserActionError ||
    error is MatrixException &&
        [
          'M_UNKNOWN_TOKEN',
          'M_FORBIDDEN',
          'M_MISSING_TOKEN',
        ].contains(error.errcode);

/// Refresh authorization from the server, never infer revocation from a cache.
Future<List<DeviceKeys>> authorizedDevices(
  Room room, {
  Set<String>? selectedUsers,
}) async {
  await room.client.getTokenOwner();
  final participants = await room.requestParticipants(
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
    throw CallAccessChanged();
  }
  final audience = members.keys.toSet();
  final peer = room.isDirectChat ? room.directChatMatrixID : null;
  if (peer != null &&
      participants.any(
        (user) =>
            [Membership.join, Membership.invite].contains(user.membership) &&
            user.id != room.client.userID &&
            user.id != peer,
      )) {
    throw UserActionError(
      'В личном диалоге обнаружен посторонний участник. Отправка остановлена.',
    );
  }
  if (peer != null && !members.containsKey(peer)) {
    if ((await room.client.getRoomStateWithKey(
          room.id,
          EventTypes.RoomMember,
          peer,
        ))['membership'] !=
        'invite') {
      throw UserActionError(
        'У собеседника больше нет доступа к этому диалогу.',
      );
    }
    final contacts = ContactService.of(room.client);
    if (contacts?.acceptsRoom(room.id, peer) != true &&
        contacts?.available == true) {
      if (room.getState('dev.voicechat.kind') == null) {
        await room.client.setRoomStateWithKey(
          room.id,
          'dev.voicechat.kind',
          '',
          {'kind': 'direct', 'owner': room.client.userID, 'peer': peer},
        );
      }
      await contacts!.request(peer, room.id);
    }
    if (contacts?.acceptsRoom(room.id, peer) != true) {
      throw UserActionError(
        'Для этого диалога пока нет подтверждённого доступа. Проверьте приглашения и соединение с сервисом контактов.',
      );
    }
    if (room.historyVisibility != HistoryVisibility.invited) {
      if (!room.canChangeHistoryVisibility) {
        throw UserActionError(
          'Не удалось обновить доступ к истории старого диалога. Требуется разрешение создателя.',
        );
      }
      await room.setHistoryVisibility(HistoryVisibility.invited);
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (room.historyVisibility != HistoryVisibility.invited) {
        if (DateTime.now().isAfter(until)) {
          throw TimeoutException('Direct history settings sync timed out');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    audience.add(peer);
  }
  if (selectedUsers != null) {
    if (!selectedUsers.contains(room.client.userID) ||
        !audience.containsAll(selectedUsers)) {
      throw CallAccessChanged();
    }
    audience.retainAll(selectedUsers);
  }
  await refreshDevices(room.client, audience);
  if (room.isDirectChat &&
      audience
          .where((u) => u != room.client.userID)
          .any(
            (u) => room.client.userDeviceKeys[u]!.deviceKeys.values.every(
              (d) => d.blocked || !d.isValid,
            ),
          )) {
    throw UserActionError(
      'У собеседника ещё нет доступного ключа. Сообщение сохранено до его входа.',
    );
  }
  await acceptFirstKeys(room.client, audience);
  final devices = audience.expand(
    (user) => room.client.userDeviceKeys[user]!.deviceKeys.values,
  );
  // Additional unverified devices receive no keys and must not block trusted recipients.
  final authorized = devices
      .where(
        (device) =>
            device.directVerified && device.encryptToDevice && !device.blocked,
      )
      .toList();
  final unverifiedUsers = audience.where(
    (user) =>
        !authorized.any((device) => device.userId == user) &&
        devices.any((device) => device.userId == user && !device.blocked),
  );
  if (unverifiedUsers.isNotEmpty) {
    final names = unverifiedUsers.map(
      (user) => user == room.client.userID ? 'ваш аккаунт' : user,
    );
    throw UserActionError(
      'Нет проверенного устройства: ${names.join(', ')}. '
      'Откройте «Настройки → Проверить устройства». '
      'Отправка приостановлена до проверки.',
    );
  }
  return authorized;
}

final _deviceRefreshes = Expando<Future<void>>();

Future<void> refreshDevices(Client client, Set<String> users) {
  // Voice and screen authorization share the SDK's mutable device lists.
  return _deviceRefreshes[client] = (_deviceRefreshes[client] ?? Future.value())
      .catchError((Object _) {})
      .then((_) async {
        for (final user in users) {
          client.userDeviceKeys[user]?.outdated = true;
        }
        await client.updateUserDeviceKeys(additionalUsers: users);
        if (users.any(
          (user) => client.userDeviceKeys[user]?.outdated != false,
        )) {
          throw StateError('Device authorization refresh failed');
        }
      });
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
  await pinManuallyVerifiedDevice(client, device);
  await device.setVerified(true, false);
}
