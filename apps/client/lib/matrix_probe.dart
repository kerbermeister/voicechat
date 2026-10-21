import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:sqflite/sqflite.dart' as sql;

/// Disposable-account laboratory. Persistent crypto storage is NOT hardened yet.
class MatrixProbe {
  static Future<void>? _cryptoInit;
  final Client client;
  StreamSubscription<UiaRequest>? _uia;
  MatrixProbe._(this.client);

  static Future<MatrixProbe> open(String profile) async {
    _cryptoInit ??= vod.init();
    await _cryptoInit;
    final name = 'voicechat_probe_${Uri.encodeComponent(profile)}';
    final db = await MatrixSdkDatabase.init(
      name,
      database: kIsWeb ? null : await sql.openDatabase('$name.db'),
      sqfliteFactory: kIsWeb ? null : sql.databaseFactory,
    );
    final client = Client(
      name,
      database: db,
      shareKeysWith: ShareKeysWith.crossVerified,
      logLevel: Level.error,
    );
    await client.init();
    return MatrixProbe._(client);
  }

  Future<void> login(String server, String username, String password) async {
    _uia = client.onUiaRequest.stream.listen((request) {
      if (request.nextStages.contains(AuthenticationTypes.password)) {
        unawaited(
          request.completeStage(
            AuthenticationPassword(
              session: request.session,
              password: password,
              identifier: AuthenticationUserIdentifier(
                user: client.userID ?? username,
              ),
            ),
          ),
        );
      } else {
        request.cancel(Exception('Unsupported authentication stage'));
      }
    });
    if (!client.isLogged()) {
      await client.checkHomeserver(Uri.parse(server));
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

  Future<String> initializeRecovery() async {
    final state = await client.getCryptoIdentityState();
    if (state.initialized) {
      throw StateError(
        'Identity already exists. Restore it; do not overwrite.',
      );
    }
    return client.initCryptoIdentity();
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
    final id = await room.sendTextEvent(text, parseCommands: false);
    if (id == null) throw StateError('Message was not sent');
    return id;
  }

  Future<void> backup() =>
      client.encryption!.keyManager.uploadInboundGroupSessions();

  Future<void> close() async {
    await _uia?.cancel();
    await client.dispose();
  }
}
