// Real VoIP sync-batch filtering and dispatch; no network, accounts or media.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/voip_id.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'direct_call_protocol_test.dart' show Capture, Delegate, Session;

class _BatchDatabase extends OutboxDatabase {
  @override
  Future<void> close() async {}
}

class _Devices extends Capture {
  Function(dynamic)? _change;
  @override
  Function(dynamic)? get ondevicechange => _change;
  @override
  set ondevicechange(Function(dynamic)? value) => _change = value;
}

class _BatchDelegate extends Delegate {
  final _devices = _Devices();
  @override
  _Devices get mediaDevices => _devices;
}

class _BatchVoip extends VoIP {
  _BatchVoip(Client client, {this.delay = Duration.zero})
    : super(client, _BatchDelegate());
  final Duration delay;
  bool failNextInvite = false;
  final invited = <String>[];
  final lifetimes = <int>[];
  @override
  Future<void> onCallInvite(
    Room room,
    String remoteUserId,
    String? remoteDeviceId,
    Map<String, dynamic> content,
  ) async {
    invited.add('${room.id}/${content['call_id']}');
    if (failNextInvite) {
      failNextInvite = false;
      throw StateError('Synthetic invite processing failure');
    }
    lifetimes.add(content['lifetime'] as int);
    if (content['call_id'] == 'slow') await Future<void>.delayed(delay);
  }
}

class _BusyDelegate extends _BatchDelegate {
  CallSession? active;
  final incoming = <CallSession>[];
  @override
  bool get canHandleNewCall => active == null || active!.callHasEnded;
  @override
  Future<void> playRingtone() async {}
  @override
  Future<void> registerListeners(CallSession session) async {}
  @override
  Future<void> handleNewCall(CallSession session) async {
    incoming.add(session);
  }

  @override
  Future<void> handleMissedCall(CallSession session) async {}
}

class _WireSession extends Session {
  _WireSession(super.opts);
  final reasons = <String?>[];
  @override
  Future<String?> sendCallReject(
    Room room,
    String callId,
    String partyId, {
    String version = '1',
    String? txid,
  }) async => 'synthetic-reject';
  @override
  Future<String?> sendHangupCall(
    Room room,
    String callId,
    String partyId,
    String? cause, {
    String version = '1',
    String? txid,
  }) async {
    reasons.add(cause);
    return super.sendHangupCall(
      room,
      callId,
      partyId,
      cause,
      version: version,
      txid: txid,
    );
  }
}

class _BusyVoip extends VoIP {
  _BusyVoip(super.client, super.delegate);
  final created = <_WireSession>[];
  @override
  Future<List<Map<String, dynamic>>> getIceServers() async => [];
  @override
  CallSession createNewCall(CallOptions opts) {
    final call = _WireSession(opts);
    calls[VoipId(roomId: opts.room.id, callId: opts.callId)] = call;
    created.add(call);
    return call;
  }
}

Event _event(
  Room room,
  String type,
  String call, {
  int age = 0,
  int lifetime = 60000,
}) => Event.fromJson({
  'event_id': '\$$type-$call-$age',
  'type': type,
  'sender': '@remote:fixture',
  'origin_server_ts': DateTime.now().millisecondsSinceEpoch - age,
  'unsigned': {'age': age},
  'content': {
    'call_id': call,
    'party_id': 'remote',
    'version': '1',
    'lifetime': lifetime,
    'offer': {'type': 'offer', 'sdp': 'synthetic'},
  },
}, room);

void main() {
  test(
    'Foreign-room hangup with the same ID preserves the current owner',
    () async {
      final client = Client('hangup-scope', database: _BatchDatabase());
      final voip = _BusyVoip(client, _BusyDelegate());
      final current = VoipId(roomId: '!current:fixture', callId: 'same-id');
      voip.currentCID = current;
      try {
        await voip.onCallHangup(Room(client: client, id: '!other:fixture'), {
          'call_id': 'same-id',
          'reason': CallErrorCode.userHangup.reason,
        });
        expect(voip.currentCID, current);
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'Failed call event does not discard a later invite in the sync batch',
    () async {
      final client = Client('batch-failure', database: _BatchDatabase());
      final voip = _BatchVoip(client)..failNextInvite = true;
      final room = Room(client: client, id: '!failure:fixture');
      try {
        client.onCallEvents.add([
          _event(room, EventTypes.CallInvite, 'failed'),
          _event(room, EventTypes.CallInvite, 'fresh'),
        ]);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(voip.invited, ['${room.id}/failed', '${room.id}/fresh']);
      } finally {
        await client.dispose();
      }
    },
  );

  for (final ending in ['timeout', 'decline', 'remote_cancel']) {
    testWidgets('Three immediate retries after $ending ignore old hangups', (
      tester,
    ) async {
      final client = Client('retry-cycles', database: _BatchDatabase());
      final delegate = _BusyDelegate();
      final voip = _BusyVoip(client, delegate);
      final room = Room(client: client, id: '!retry:fixture');
      try {
        for (var cycle = 0; cycle < 3; cycle++) {
          final id = 'call-$cycle';
          await voip.onCallInvite(
            room,
            '@peer:fixture',
            null,
            _event(room, EventTypes.CallInvite, id, lifetime: 1000).content,
          );
          final call = voip.created.last;
          expect(call.state, CallState.kRinging);
          delegate.active = call;
          if (cycle > 0) {
            await voip.onCallHangup(room, {
              'call_id': 'call-${cycle - 1}',
              'reason': CallErrorCode.userHangup.reason,
            });
            expect(call.state, CallState.kRinging);
            expect(voip.currentCID, VoipId(roomId: room.id, callId: id));
          }
          if (ending == 'timeout') {
            await tester.pump(const Duration(seconds: 1));
          } else if (ending == 'decline') {
            await call.reject();
          } else {
            await voip.onCallHangup(room, {
              'call_id': id,
              'reason': CallErrorCode.userHangup.reason,
            });
          }
          expect(call.callHasEnded, isTrue);
          expect(voip.currentCID, isNull);
          expect(voip.calls, isEmpty);
          expect(delegate.canHandleNewCall, isTrue);
        }
        expect(delegate.incoming, hasLength(3));
        expect(delegate.mediaDevices.requested.isCompleted, isFalse);
      } finally {
        for (final call in voip.created) {
          await call.hangup(reason: CallErrorCode.userHangup);
        }
        await client.dispose();
      }
    });
  }

  test(
    'Invite age includes time spent dispatching earlier sync events',
    () async {
      final client = Client('batch-delay', database: _BatchDatabase());
      final voip = _BatchVoip(client, delay: const Duration(milliseconds: 80));
      final room = Room(client: client, id: '!delay:fixture');
      final second = _event(
        room,
        EventTypes.CallInvite,
        'expired-while-waiting',
        lifetime: 30,
      );
      try {
        client.onCallEvents.add([
          _event(room, EventTypes.CallInvite, 'slow'),
          second,
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(voip.invited, ['${room.id}/slow']);
        expect(
          second.content['lifetime'],
          30,
          reason: 'Do not rewrite the shared event',
        );
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'Dispatch passes only the remaining lifetime without mutating the event',
    () async {
      final client = Client('batch-age', database: _BatchDatabase());
      final voip = _BatchVoip(client);
      final room = Room(client: client, id: '!age:fixture');
      final invite = _event(
        room,
        EventTypes.CallInvite,
        'old-but-valid',
        age: 40000,
      );
      try {
        client.onCallEvents.add([invite]);
        await Future<void>.delayed(Duration.zero);
        expect(voip.lifetimes.single, inInclusiveRange(19000, 20000));
        expect(invite.content['lifetime'], 60000);
      } finally {
        await client.dispose();
      }
    },
  );

  test('Crossing outgoing calls notify busy and allow a fresh callback', () async {
    final clients = [
      Client('glare-a', database: _BatchDatabase()),
      Client('glare-b', database: _BatchDatabase()),
    ];
    final delegates = [_BusyDelegate(), _BusyDelegate()];
    final voips = [
      for (var i = 0; i < 2; i++) _BusyVoip(clients[i], delegates[i]),
    ];
    final rooms = [
      for (final client in clients) Room(client: client, id: '!glare:fixture'),
    ];
    final originals = <CallSession>[];
    for (var i = 0; i < 2; i++) {
      final id = 'outgoing-$i';
      final call = voips[i].createNewCall(
        CallOptions(
          callId: id,
          type: CallType.kVoice,
          dir: CallDirection.kOutgoing,
          localPartyId: voips[i].localPartyId,
          voip: voips[i],
          room: rooms[i],
          iceServers: [],
        ),
      );
      call.setCallState(CallState.kInviteSent);
      voips[i].currentCID = VoipId(roomId: rooms[i].id, callId: id);
      voips[i].incomingCallRoomId[rooms[i].id] = id;
      delegates[i].active = call;
      originals.add(call);
    }
    try {
      await Future.wait([
        for (var i = 0; i < 2; i++)
          voips[i].onCallInvite(
            rooms[i],
            '@peer:fixture',
            null,
            _event(
              rooms[i],
              EventTypes.CallInvite,
              originals[1 - i].callId,
            ).content,
          ),
      ]);
      // ignore: avoid_print
      print(
        'CALL_GLARE_PROOF ${jsonEncode({
          'busy_wire_replies': [for (final voip in voips) voip.created.last.reasons],
          'originals_preserved': [for (final call in originals) !call.callHasEnded],
          'capture_requests': [for (final delegate in delegates) delegate.mediaDevices.requested.isCompleted],
        })}',
      );
      for (var i = 0; i < 2; i++) {
        expect(
          voips[i].created.last.reasons,
          [CallErrorCode.userBusy.reason],
          reason:
              'Busy must reach the caller rather than leaving it ringing silently',
        );
        expect(originals[i].callHasEnded, isFalse);
        expect(delegates[i].mediaDevices.requested.isCompleted, isFalse);
        await voips[i].onCallHangup(rooms[i], {
          'call_id': originals[i].callId,
          'reason': CallErrorCode.userBusy.reason,
        });
        expect(delegates[i].canHandleNewCall, isTrue);
        await voips[i].onCallInvite(
          rooms[i],
          '@peer:fixture',
          null,
          _event(rooms[i], EventTypes.CallInvite, 'fresh-$i').content,
        );
        expect(delegates[i].incoming.single.state, CallState.kRinging);
        expect(
          voips[i].currentCID,
          VoipId(roomId: rooms[i].id, callId: 'fresh-$i'),
        );
      }
    } finally {
      for (final voip in voips) {
        for (final call in voip.created) {
          if (!call.callHasEnded) {
            await call.hangup(reason: CallErrorCode.userHangup);
          }
          await call.cleanUp();
        }
      }
      for (final client in clients) {
        await client.dispose();
      }
    }
  });

  for (final scenario in [
    'fresh_only',
    'expired_first',
    'expired_last',
    'exact_expiry',
    'foreign_room_end',
    'same_room_end',
  ]) {
    test('VoIP sync batch preserves fresh call: $scenario', () async {
      final client = Client('batch', database: _BatchDatabase());
      final voip = _BatchVoip(client);
      final room = Room(client: client, id: '!same:fixture');
      final fresh = _event(room, EventTypes.CallInvite, 'fresh');
      final expired = _event(
        room,
        EventTypes.CallInvite,
        'old',
        age: scenario == 'exact_expiry' ? 60000 : 65000,
      );
      final events = <BasicEventWithSender>[fresh];
      if (scenario == 'expired_first' || scenario == 'exact_expiry') {
        events.insert(0, expired);
      }
      if (scenario == 'expired_last') events.add(expired);
      if (scenario.endsWith('_room_end')) {
        final endRoom = scenario == 'foreign_room_end'
            ? Room(client: client, id: '!other:fixture')
            : room;
        events.add(_event(endRoom, EventTypes.CallHangup, 'fresh'));
      }
      final input = List<BasicEventWithSender>.of(events);
      try {
        client.onCallEvents.add(events);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        final expected = scenario == 'same_room_end'
            ? <String>[]
            : ['${room.id}/fresh'];
        // ignore: avoid_print
        print(
          'CALL_BATCH_PROOF ${jsonEncode({'scenario': scenario, 'dispatched': voip.invited, 'expected': expected, 'shared_batch_preserved': events.length == input.length})}',
        );
        expect(voip.invited, expected);
        expect(
          events,
          input,
          reason:
              'SDK must not mutate the list shared with other call listeners',
        );
      } finally {
        await client.dispose();
      }
    });
  }
}
