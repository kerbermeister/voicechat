import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/encryption.dart';
import 'package:voicechat_probe/matrix_probe.dart';

class TestRoom implements Room {
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

class TestClient implements Client {
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
  String get deviceId => 'DEVICE';
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

void main() {
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
      await expectLater(MatrixProbe.sendText(room, 'hello'), throwsStateError);
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
