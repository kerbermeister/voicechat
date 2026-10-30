// ignore: implementation_imports
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/encryption.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/contact_service.dart';

class TestRoom implements Room {
  @override
  final roomAccountData = <String, BasicEvent>{};
  @override
  final bool encrypted;
  @override
  bool get isDirectChat => false;
  final String? result;
  bool sent = false;
  @override
  final TestClient client = TestClient();
  @override
  String get id => '!room:local';
  TestRoom(this.encrypted, this.result);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #requestParticipants) {
      return Future.value(<User>[]);
    }
    if (invocation.memberName == #sendTextEvent) {
      expect(invocation.namedArguments[#parseCommands], false);
      sent = true;
      return Future<String?>.value(result);
    }
    return super.noSuchMethod(invocation);
  }
}

class FixtureAccountDatabase implements DatabaseApi {
  final values = <String, BasicEvent>{};
  @override
  Future<Map<String, BasicEvent>> getAccountData() async => Map.of(values);
  @override
  Future<void> storeAccountData(
    String type,
    Map<String, Object?> content,
  ) async {
    values[type] = BasicEvent(type: type, content: content);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestClient implements Client {
  final _sync = CachedStreamController<SyncUpdate>();
  @override
  CachedStreamController<SyncUpdate> get onSync => _sync;
  final _database = FixtureAccountDatabase();
  @override
  DatabaseApi get database => _database;
  @override
  final onPresenceChanged = CachedStreamController<CachedPresence>();
  @override
  final presences = <String, CachedPresence>{};
  @override
  String get userID => '@user:local';
  @override
  Uri get homeserver => Uri.parse('https://example.invalid');
  @override
  String get accessToken => 'test-token';
  @override
  final httpClient = MockClient((_) async => http.Response('{}', 503));
  bool cleared = false;
  @override
  late final userDeviceKeys = {userID: DeviceKeysList(userID, this)};
  @override
  final encryption = TestEncryption();
  bool failRefresh = false;
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #clear) {
      cleared = true;
      return Future<void>.value();
    }
    if (i.memberName == #getTokenOwner) {
      return Future.value(TokenOwnerInfo(userId: userID));
    }
    if (i.memberName == #getJoinedMembersByRoom) {
      return Future.value(<String, RoomMember>{userID: RoomMember()});
    }
    if (i.memberName == #updateUserDeviceKeys) {
      if (!failRefresh) userDeviceKeys[userID]!.outdated = false;
      return Future<void>.value();
    }
    return super.noSuchMethod(i);
  }
}

class TestEncryption implements Encryption {
  @override
  final keyManager = TestKeys();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class TestKeys implements KeyManager {
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #uploadInboundGroupSessions) {
      return Future<void>.value();
    }
    if (i.memberName == #clearOrUseOutboundGroupSession) {
      expect(i.namedArguments[#wipe], true);
      return Future.value(true);
    }
    return super.noSuchMethod(i);
  }
}

class TestDevice implements DeviceKeys {
  @override
  String get userId => '@user:local';
  @override
  String get deviceId => id;
  final String id;
  TestDevice([this.id = 'DEVICE']);
  @override
  String get ed25519Key => 'expected-fingerprint';
  @override
  bool get blocked => false;
  @override
  bool directVerified = false;
  @override
  bool get encryptToDevice => directVerified;
  @override
  Future<void> setVerified(bool value, [bool sign = true]) async {
    expect(sign, false);
    directVerified = value;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class LoggedInClient extends TestClient {
  @override
  bool isLogged() => true;
  @override
  Future<SyncUpdate> get firstSyncReceived async => SyncUpdate(nextBatch: '');
  @override
  bool get encryptionEnabled => true;
}

class OfflinePeer extends TestDevice {
  @override
  String get userId => '@peer:local';
  @override
  bool get isValid => true;
}

class OfflineClient extends TestClient {
  String peerMembership = 'invite';
  OfflineClient() {
    userDeviceKeys['@peer:local'] = DeviceKeysList(
      '@peer:local',
      this,
      deviceKeys: {'DEVICE': OfflinePeer()..directVerified = true},
    );
  }
  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {
    for (final list in userDeviceKeys.values) {
      list.outdated = false;
    }
  }

  @override
  Future<Map<String, Object?>> getRoomStateWithKey(
    String roomId,
    String eventType,
    String stateKey, {
    Format? format,
  }) async => {'membership': peerMembership};
}

class OfflineRoom extends TestRoom {
  final _client = OfflineClient();
  @override
  OfflineClient get client => _client;
  @override
  bool get isDirectChat => true;
  @override
  String get directChatMatrixID => '@peer:local';
  HistoryVisibility visibility = HistoryVisibility.invited;
  bool canMigrate = true;
  bool intruder = false;
  @override
  Future<List<User>> requestParticipants([
    List<Membership> membershipFilter = const [
      Membership.join,
      Membership.invite,
      Membership.knock,
    ],
    bool suppressWarning = false,
    bool? cache,
    bool enforceFetchFromServer = false,
  ]) async => [
    if (intruder) User('@intruder:local', membership: 'join', room: this),
  ];
  @override
  bool get canChangeHistoryVisibility => canMigrate;
  @override
  Future<void> setHistoryVisibility(HistoryVisibility value) async =>
      visibility = value;
  @override
  HistoryVisibility get historyVisibility => visibility;
  OfflineRoom() : super(true, 'event');
}

class SyncClient extends TestClient {
  late Room syncingRoom;
  @override
  Room? getRoomById(String id) => syncingRoom.id == id ? syncingRoom : null;
}

void main() {
  test(
    'An offline invited peer needs explicit contact consent, current membership and a valid device key',
    () async {
      final room = OfflineRoom();
      await expectLater(authorizedDevices(room), throwsStateError);
      final service = ContactService(room.client, 'http://localhost:8090');
      addTearDown(service.close);
      ContactRequest consent(String state) => ContactRequest.fromJson({
        'id': 'a' * 32,
        'sender': room.client.userID,
        'recipient': room.directChatMatrixID,
        'room_id': room.id,
        'state': state,
      });
      service.requests = [consent('pending')];
      await expectLater(authorizedDevices(room), throwsStateError);
      service.requests = [consent('accepted')];
      expect(
        (await authorizedDevices(room)).single.userId,
        room.directChatMatrixID,
      );
      room.intruder = true;
      await expectLater(authorizedDevices(room), throwsStateError);
      room.intruder = false;
      room.client.peerMembership = 'leave';
      await expectLater(authorizedDevices(room), throwsStateError);
      room.client.peerMembership = 'invite';
      room.visibility = HistoryVisibility.joined;
      room.canMigrate = false;
      await expectLater(authorizedDevices(room), throwsStateError);
      room.canMigrate = true;
      expect(
        (await authorizedDevices(room)).single.userId,
        room.directChatMatrixID,
      );
      expect(room.visibility, HistoryVisibility.invited);
      room.client.userDeviceKeys[room.directChatMatrixID]!.deviceKeys.clear();
      await expectLater(authorizedDevices(room), throwsStateError);
    },
  );

  test(
    'A newly joined room waits for encrypted state before it becomes usable',
    () async {
      final client = SyncClient();
      final room = client.syncingRoom = Room(id: '!sync:local', client: client);
      final timer = Timer(const Duration(milliseconds: 10), () {
        room.states[EventTypes.Encryption] = {
          '': StrippedStateEvent(
            type: EventTypes.Encryption,
            stateKey: '',
            senderId: client.userID,
            content: {'algorithm': 'm.megolm.v1.aes-sha2'},
          ),
        };
      });
      addTearDown(timer.cancel);
      expect(room.encrypted, false);
      expect(await MatrixProbe(client).room(room.id), same(room));
      expect(room.encrypted, true);
    },
  );

  test(
    'An existing profile cannot silently open the wrong account or server',
    () async {
      final probe = MatrixProbe(LoggedInClient());
      await expectLater(
        probe.login('https://example.invalid', 'other', ''),
        throwsStateError,
      );
      await expectLater(
        probe.login('https://other.invalid', 'user', ''),
        throwsStateError,
      );
      await probe.login('https://example.invalid', 'user', '');
    },
  );

  test(
    'Unverified device blocks sending; only the matching fingerprint grants trust',
    () async {
      final room = TestRoom(true, 'event');
      final device = TestDevice();
      room.client.userDeviceKeys[room.client.userID]!.deviceKeys[device
              .deviceId] =
          device;
      await expectLater(
        MatrixProbe.sendText(room, 'hello'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'identifies whose device needs verification',
            contains('ваш аккаунт'),
          ),
        ),
      );
      expect(room.sent, false);
      await expectLater(
        verifyDevice(room.client, device.userId, device.deviceId, 'wrong'),
        throwsStateError,
      );
      expect(device.directVerified, false);
      await verifyDevice(
        room.client,
        device.userId,
        device.deviceId,
        'expected-fingerprint',
      );
      expect(device.directVerified, true);
      expect(await MatrixProbe.sendText(room, 'hello'), 'event');
    },
  );
  test(
    'An extra unverified device neither blocks a trusted device nor receives keys',
    () async {
      final room = TestRoom(true, 'event');
      final trusted = TestDevice('TRUSTED')..directVerified = true;
      final unverified = TestDevice('UNVERIFIED');
      room.client.userDeviceKeys[room.client.userID]!.deviceKeys.addAll({
        trusted.deviceId: trusted,
        unverified.deviceId: unverified,
      });
      expect(await authorizedDevices(room), [trusted]);
      expect(await MatrixProbe.sendText(room, 'hello'), 'event');
      expect(unverified.directVerified, false);
      expect(unverified.encryptToDevice, false);
    },
  );
  test('Failed server logout preserves the local session', () async {
    final client = TestClient();
    await expectLater(MatrixProbe(client).logout(), throwsA(anything));
    expect(client.cleared, false);
  });
  test('A failed authorization refresh prevents sending', () async {
    final room = TestRoom(true, 'event');
    room.client.failRefresh = true;
    await expectLater(MatrixProbe.sendText(room, 'hello'), throwsStateError);
    expect(room.sent, false);
  });
  test(
    'Only confirmed encrypted sends succeed; slash text stays text',
    () async {
      final plaintext = TestRoom(false, 'event');
      await expectLater(
        MatrixProbe.sendText(plaintext, 'hello'),
        throwsStateError,
      );
      expect(plaintext.sent, false);
      await expectLater(
        MatrixProbe.sendText(TestRoom(true, null), 'hello'),
        throwsStateError,
      );
      expect(
        await MatrixProbe.sendText(TestRoom(true, 'event'), '/hello'),
        'event',
      );
    },
  );
}
