import 'dart:collection';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_probe.dart';
import 'package:voicechat_probe/matrix_probe.dart' show CallAccessChanged;
import 'message_test.dart' show TestClient, TestDevice, TestRoom;

class SharingDevice extends TestDevice {
  @override
  final String deviceId;
  SharingDevice(this.deviceId) {
    directVerified = true;
  }
  @override
  String get curve25519Key => 'curve-$deviceId';
}

class SharingClient extends TestClient {
  int sends = 0;
  int checks = 0;
  Completer<TokenOwnerInfo>? pendingCheck;
  @override
  String get deviceID => 'CURRENT';
  @override
  Future<TokenOwnerInfo> getTokenOwner() async {
    checks++;
    if (pendingCheck != null) return pendingCheck!.future;
    return TokenOwnerInfo(userId: userID);
  }

  @override
  Future<void> sendToDeviceEncrypted(
    List<DeviceKeys> devices,
    String type,
    Map<String, dynamic> content, {
    String? messageId,
    bool onlyVerified = false,
  }) async {
    sends++;
  }
}

class SharingRoom extends TestRoom {
  final SharingClient _client;
  @override
  SharingClient get client => _client;
  SharingRoom(this._client) : super(true, null);
}

class SharingMedia implements lk.Room {
  final peers = <String, lk.RemoteParticipant>{};
  @override
  UnmodifiableMapView<String, lk.RemoteParticipant> get remoteParticipants =>
      UnmodifiableMapView(peers);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SharingPeer implements lk.RemoteParticipant {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'Key repeats are bounded; access, new recipients and repairs are not',
    (tester) async {
      final client = SharingClient();
      final devices = client.userDeviceKeys[client.userID]!.deviceKeys;
      devices['A'] = SharingDevice('A');
      devices['B'] = SharingDevice('B');
      final media = SharingMedia();
      media.peers['${client.userID}/A'] = SharingPeer();
      final call = CallProbe(
        chat: SharingRoom(client),
        session: 'test',
        tokenUrl: 'http://localhost:8090',
        livekitUrl: 'ws://localhost:7880',
        status: (_) {},
      )..media = media;
      await call.shareKey(force: false);
      await call.shareKey(force: false);
      expect(client.sends, 1);
      expect(client.checks, 2);
      media.peers['${client.userID}/B'] = SharingPeer();
      await call.shareKey(force: false);
      expect(client.sends, 2);
      await call.shareKey();
      expect(client.sends, 3);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 9)),
      );
      await call.shareKey(force: false);
      expect(client.sends, 4);
      devices.remove('B');
      await expectLater(
        call.shareKey(force: false),
        throwsA(isA<CallAccessChanged>()),
      );
      expect(client.sends, 4);
      expect(client.checks, 6);
      final pending = client.pendingCheck = Completer<TokenOwnerInfo>();
      final first = call.shareKey(), second = call.shareKey(force: false);
      expect(identical(first, second), true);
      final failure = StateError('authorization unavailable');
      final firstResult = expectLater(first, throwsA(same(failure)));
      final secondResult = expectLater(second, throwsA(same(failure)));
      pending.completeError(failure);
      await Future.wait([firstResult, secondResult]);
      expect(client.checks, 7);
    },
  );
}
