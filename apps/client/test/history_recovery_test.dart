import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
// ignore: implementation_imports
import 'package:matrix/encryption/utils/session_key.dart';
// ignore: implementation_imports
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:voicechat_probe/first_keys.dart';
import 'package:voicechat_probe/history_recovery.dart';
import 'package:voicechat_probe/user_action_error.dart';
import 'first_keys_test.dart' show PinClient, PinDevice;
import 'chat_actions_test.dart' show OutboxRoom, OutboxTimeline;

class RecoveryDevice extends PinDevice {
  bool denied = false;
  RecoveryDevice() : super('@alice:local', 'ALICE', 'original');
  @override
  bool get blocked => denied;
}

class RecoverySession implements SessionKey {
  @override
  bool get isValid => true;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class RecoveryManager implements KeyManager {
  @override
  final Client client;
  RecoveryManager(this.client);
  void Function()? loading;
  @override
  final incomingShareRequests = <String, KeyManagerKeyShareRequest>{};
  @override
  Future<SessionKey?> loadInboundGroupSession(
    String roomId,
    String sessionId,
  ) async {
    loading?.call();
    return RecoverySession();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class RecoveryEncryption implements Encryption {
  @override
  final KeyManager keyManager;
  RecoveryEncryption(this.keyManager);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class RecoveryClient extends PinClient {
  @override
  String get userID => '@bob:local';
  final _incoming = CachedStreamController<RoomKeyRequest>();
  @override
  CachedStreamController<RoomKeyRequest> get onRoomKeyRequest => _incoming;
  late final manager = RecoveryManager(this);
  @override
  late final encryption = RecoveryEncryption(manager);
  bool joined = true;
  String history = 'shared';
  @override
  Future<Map<String, Object?>> getRoomStateWithKey(
    String roomId,
    String eventType,
    String stateKey, {
    Format? format,
  }) async => {'history_visibility': history};
  Completer<void>? refreshing;
  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {
    await refreshing?.future;
    for (final list in userDeviceKeys.values) {
      list.outdated = false;
    }
  }

  @override
  Future<Map<String, RoomMember>?> getJoinedMembersByRoom(
    String roomId,
  ) async => {userID: RoomMember(), if (joined) '@alice:local': RoomMember()};
}

class SharedHistoryRoom extends OutboxRoom {
  SharedHistoryRoom(super.client);
  @override
  HistoryVisibility get historyVisibility => HistoryVisibility.shared;
}

class HistoryRequest extends RoomKeyRequest {
  int sent = 0;
  HistoryRequest(RecoveryClient client, DeviceKeys device, {Room? room})
    : super.fromToDeviceEvent(
        ToDeviceEvent(
          sender: device.userId,
          type: EventTypes.RoomKeyRequest,
          content: {},
        ),
        client.manager,
        KeyManagerKeyShareRequest(
          requestId: 'request',
          room: room ?? OutboxRoom(client),
          sessionId: 'session',
          devices: [device],
        ),
      );
  @override
  Future<void> forwardKey([int? index]) async {
    sent++;
  }
}

class MissingEvent extends Event {
  int requests = 0;
  bool fail = false;
  MissingEvent(Room room, String session)
    : super(
        type: EventTypes.Encrypted,
        content: {
          'msgtype': MessageTypes.BadEncrypted,
          'can_request_session': true,
          'session_id': session,
        },
        room: room,
        senderId: '@alice:local',
        eventId: '\$event-$session',
        originServerTs: DateTime.now(),
      );
  @override
  Future<void> requestKey() async {
    requests++;
    if (fail) throw TimeoutException('offline');
  }
}

void main() {
  for (final scenario in [
    'verified',
    'unverified',
    'left',
    'policy changed',
    'left while loading',
  ]) {
    test(
      'Shared group automatically forwards old keys only when safe: $scenario',
      () async {
        final client = RecoveryClient();
        enableFirstContactTrust(client);
        final device = RecoveryDevice()..directVerified = true;
        client.userDeviceKeys[device.userId] = DeviceKeysList(
          device.userId,
          client,
          deviceKeys: {device.deviceId: device},
        );
        if (scenario != 'unverified') {
          await pinManuallyVerifiedDevice(client, device);
        }
        if (scenario == 'left') client.joined = false;
        if (scenario == 'policy changed') client.history = 'joined';
        if (scenario == 'left while loading') {
          client.manager.loading = () => client.joined = false;
        }
        final owner = HistoryRecovery(client, () {});
        final request = HistoryRequest(
          client,
          device,
          room: SharedHistoryRoom(client),
        );
        client.onRoomKeyRequest.add(request);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(request.sent, scenario == 'verified' ? 1 : 0);
        expect(owner.pending.length, scenario == 'verified' ? 0 : 1);
        await owner.close();
      },
    );
  }
  test(
    'TOFU alone cannot release old keys; independent exact-device proof can',
    () async {
      final client = RecoveryClient();
      enableFirstContactTrust(client);
      final device = RecoveryDevice()..directVerified = true;
      client.userDeviceKeys[device.userId] = DeviceKeysList(
        device.userId,
        client,
        deviceKeys: {device.deviceId: device},
      );
      final owner = HistoryRecovery(client, () {});
      final request = HistoryRequest(client, device);
      client.onRoomKeyRequest.add(request);
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        owner.approve(request),
        throwsA(isA<UserActionError>()),
      );
      expect(request.sent, 0);
      await pinManuallyVerifiedDevice(client, device);
      await owner.approve(request);
      expect(request.sent, 1);
      expect(owner.pending, isEmpty);
      await expectLater(
        owner.approve(request),
        throwsA(isA<UserActionError>()),
      );
      await owner.close();
    },
  );

  for (final refusal in [
    'changed',
    'blocked',
    'left',
    'canceled',
    'locked',
    'canceled while loading',
  ]) {
    test('No key is released when recipient is $refusal', () async {
      final client = RecoveryClient();
      enableFirstContactTrust(client);
      final device = RecoveryDevice()..directVerified = true;
      final list = DeviceKeysList(
        device.userId,
        client,
        deviceKeys: {device.deviceId: device},
      );
      client.userDeviceKeys[device.userId] = list;
      await pinManuallyVerifiedDevice(client, device);
      final owner = HistoryRecovery(client, () {});
      final request = HistoryRequest(client, device);
      client.onRoomKeyRequest.add(request);
      await Future<void>.delayed(Duration.zero);
      switch (refusal) {
        case 'changed':
          list.deviceKeys[device.deviceId] = PinDevice(
            device.userId,
            device.deviceId,
            'replacement',
          )..directVerified = true;
        case 'blocked':
          device.denied = true;
        case 'left':
          client.joined = false;
        case 'canceled':
          request.request.canceled = true;
        case 'locked':
          client.refreshing = Completer<void>();
        case 'canceled while loading':
          client.manager.loading = () => request.request.canceled = true;
      }
      final approval = owner.approve(request);
      if (refusal == 'locked') {
        await owner.close();
        client.refreshing!.complete();
      }
      await expectLater(approval, throwsA(isA<UserActionError>()));
      expect(request.sent, 0);
      await owner.close();
    });
  }

  test(
    'Requests received during initial sync are retained and cancellation is checked after key loading',
    () async {
      final client = RecoveryClient();
      final request = HistoryRequest(client, RecoveryDevice());
      client.manager.incomingShareRequests['request'] = request.request;
      final owner = HistoryRecovery(client, () {});
      expect(owner.pending, hasLength(1));
      client.manager.loading = () => request.request.canceled = true;
      final actual = RoomKeyRequest.fromToDeviceEvent(
        request,
        client.manager,
        request.request,
      );
      await actual.forwardKey();
      expect(request.request.canceled, true);
      await owner.close();
    },
  );

  test(
    'Missing history requests deduplicate sessions and propagate failures',
    () async {
      final room = OutboxRoom(RecoveryClient());
      final first = MissingEvent(room, 'one');
      final duplicate = MissingEvent(room, 'one');
      expect(
        await requestMissingHistory(OutboxTimeline([first, duplicate])),
        1,
      );
      expect(first.requests, 1);
      expect(duplicate.requests, 0);
      final failed = MissingEvent(room, 'two')..fail = true;
      await expectLater(
        requestMissingHistory(OutboxTimeline([failed])),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
}
