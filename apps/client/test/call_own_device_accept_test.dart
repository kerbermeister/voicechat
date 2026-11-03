import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'call_devices_test.dart' show DeviceClient, DeviceRoom, DirectDeviceRoom;
import 'direct_call_protocol_test.dart' show Session;

void _otherDeviceSignal(
  CallController calls,
  DeviceClient client,
  Room room,
  String session,
  String action,
  String scope,
) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final sender = scope == 'other_sender' ? '@other:local' : client.userID;
  final curve = scope == 'unknown_key' ? 'unknown' : 'trusted';
  if (action != 'answered') {
    calls.receive(
      Event.fromJson({
        'type': action == 'reject'
            ? EventTypes.CallReject
            : EventTypes.CallHangup,
        'event_id': r'$own-end',
        'sender': sender,
        'origin_server_ts': now,
        'content': {
          'call_id': session,
          'party_id': 'other-own-party',
          'version': '1',
          'reason': 'user_hangup',
        },
        if (scope != 'plaintext')
          'original_source': {
            'type': EventTypes.Encrypted,
            'event_id': r'$own-end',
            'sender': sender,
            'origin_server_ts': now,
            'content': {'sender_key': curve},
          },
      }, room),
    );
  } else {
    calls.devices.receive(
      ToDeviceEvent(
        sender: sender,
        type: 'dev.voicechat.call_device',
        encryptedContent: scope == 'plaintext' ? null : {'sender_key': curve},
        content: {
          'room_id': room.id,
          'session': session,
          'device': 'PHONE',
          'active': true,
          'sent_at': now,
        },
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          (_) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          null,
        );
  });

  for (final type in [CallType.kVoice, CallType.kVideo]) {
    for (final stage in ['push', 'media']) {
      for (final action in ['hangup', 'reject', 'answered']) {
        for (final scope in [
          'valid',
          'other_room',
          'other_session',
          'other_sender',
          'unknown_key',
          'unverified',
          'plaintext',
          'accepted',
          'connected',
        ]) {
          if (type == CallType.kVideo &&
              scope != 'valid' &&
              scope != 'connected') {
            continue;
          }
          test(
            'Own-device ${type.name} $action during $stage: $scope',
            () async {
              final entered = Completer<void>(), media = Completer<void>();
              final push = Completer<http.Response>();
              final client = DeviceClient(
                httpClient: MockClient((_) {
                  if (stage == 'push') {
                    entered.complete();
                    return push.future;
                  }
                  return Future.value(http.Response('{}', 200));
                }),
              );
              final room = DirectDeviceRoom(client);
              final other = DirectDeviceRoom(client, id: '!other:local');
              client.rooms.addAll([room, other]);
              final calls = CallController(
                client,
                'http://localhost',
                'ws://localhost',
                (_) {},
                beforeMedia: () {
                  if (stage == 'media') entered.complete();
                  return media.future;
                },
              );
              final session = Session(
                CallOptions(
                  callId: 'pending',
                  type: type,
                  dir: CallDirection.kIncoming,
                  localPartyId: 'local',
                  voip: calls.voip,
                  room: room,
                  iceServers: [],
                ),
              )..setCallState(CallState.kRinging);
              final incoming = DirectCall(session, () {}, (_) {});
              calls.directInvitations.add(incoming);
              var finished = false;
              final accepting = calls
                  .acceptDirect(incoming)
                  .then((_) => finished = true);
              try {
                await entered.future;
                expect(
                  calls.directInvitations,
                  isEmpty,
                  reason: 'Acceptance reserved the active slot',
                );
                if (scope == 'accepted') calls.devices.accept(incoming);
                if (scope == 'connected') {
                  session.setCallState(CallState.kConnected);
                }
                if (scope == 'unverified') {
                  client.trusted.directVerified = false;
                }
                void signal() => _otherDeviceSignal(
                  calls,
                  client,
                  scope == 'other_room' ? other : room,
                  scope == 'other_session' ? 'different' : session.callId,
                  action,
                  scope,
                );
                signal();
                if (scope == 'valid') signal();
                await Future<void>.delayed(Duration.zero);
                final cancelled = scope == 'valid';
                expect(incoming.isClosed, cancelled);
                expect(finished, cancelled);
                expect(calls.canHandleNewCall, cancelled);
                expect(session.answers, 0);
                expect(
                  session.hangups,
                  0,
                  reason: 'Own-device suppression must not echo a room hangup',
                );
              } finally {
                await calls.end();
                if (!push.isCompleted) push.complete(http.Response('{}', 200));
                media.complete();
                await accepting;
                await incoming.close();
                await calls.close();
                await client.dispose();
              }
            },
          );
        }
      }
    }
  }

  for (final failure in {'answered_elsewhere': 0, 'unavailable': 1}.entries) {
    test(
      'Push claim ${failure.key}: terminal room messages ${failure.value}',
      () async {
        final client = DeviceClient(
          httpClient: MockClient(
            (_) async => http.Response(
              '{"error":"${failure.key}"}',
              failure.key == 'answered_elsewhere' ? 409 : 503,
            ),
          ),
        );
        final room = DirectDeviceRoom(client);
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          (_) {},
        );
        final session = Session(
          CallOptions(
            callId: 'losing-claim',
            type: CallType.kVoice,
            dir: CallDirection.kIncoming,
            localPartyId: 'local',
            voip: calls.voip,
            room: room,
            iceServers: [],
          ),
        )..setCallState(CallState.kRinging);
        final incoming = DirectCall(session, () {}, (_) {});
        calls.directInvitations.add(incoming);
        try {
          await calls.acceptDirect(incoming);
          expect(incoming.isClosed, isTrue);
          expect(session.answers, 0);
          expect(
            session.hangups,
            failure.value,
            reason:
                'A losing device must not cancel the winner; other failures retain caller cancellation',
          );
        } finally {
          await incoming.close();
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  for (final failure in ['answered_elsewhere', 'unavailable']) {
    test(
      'Group push claim $failure retains only retryable invitations',
      () async {
        final client = DeviceClient(
          httpClient: MockClient(
            (_) async => http.Response(
              '{"error":"$failure"}',
              failure == 'answered_elsewhere' ? 409 : 503,
            ),
          ),
        );
        final room = DeviceRoom(client);
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          (_) {},
          beforeMedia: () async => fail('A rejected claim cannot open media'),
        );
        final invitation = CallInvitation(
          room,
          'a' * 32,
          '@peer:local',
          DateTime.now(),
        );
        calls.invitations[invitation.session] = invitation;
        try {
          await calls.start(room, invitation: invitation);
          expect(
            calls.invitations.containsKey(invitation.session),
            failure == 'unavailable',
          );
          expect(calls.starting, isFalse);
          expect(calls.active, isNull);
        } finally {
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  for (final nextSetup in [false, true]) {
    test(
      'Own-device cleanup error belongs only to its attempt: next=$nextSetup',
      () async {
        final entered = [Completer<void>(), Completer<void>()];
        final media = [Completer<void>(), Completer<void>()];
        final cleanup = Completer<void>();
        final reports = <String>[];
        var preparations = 0;
        final client = DeviceClient(
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        );
        final room = DirectDeviceRoom(client);
        client.rooms.add(room);
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          reports.add,
          beforeMedia: () {
            final index = preparations++;
            entered[index].complete();
            return media[index].future;
          },
        );
        final session =
            Session(
                CallOptions(
                  callId: 'cleanup-owner',
                  type: CallType.kVoice,
                  dir: CallDirection.kIncoming,
                  localPartyId: 'local',
                  voip: calls.voip,
                  room: room,
                  iceServers: [],
                ),
              )
              ..setCallState(CallState.kRinging)
              ..cleanup = cleanup;
        final incoming = DirectCall(session, () {}, reports.add);
        calls.directInvitations.add(incoming);
        final accepting = calls.acceptDirect(incoming);
        Future<void>? next;
        try {
          await entered[0].future;
          _otherDeviceSignal(
            calls,
            client,
            room,
            session.callId,
            'hangup',
            'valid',
          );
          await accepting.timeout(const Duration(seconds: 1));
          if (nextSetup) {
            next = calls.start(DirectDeviceRoom(client, id: '!next:local'));
            await entered[1].future;
            expect(calls.active, isNull);
          }
          cleanup.completeError(StateError('Synthetic native cleanup failure'));
          await Future<void>.delayed(Duration.zero);
          expect(reports.length, nextSetup ? 0 : 1);
        } finally {
          if (!cleanup.isCompleted) cleanup.complete();
          await calls.end();
          for (final gate in media) {
            gate.complete();
          }
          await accepting;
          await next;
          await incoming.close();
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  test(
    'Remote ending releases acceptance before SDK cleanup finishes',
    () async {
      final entered = Completer<void>(), media = Completer<void>();
      final cleanup = Completer<void>();
      final client = DeviceClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final room = DirectDeviceRoom(client);
      client.rooms.add(room);
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
        beforeMedia: () {
          entered.complete();
          return media.future;
        },
      );
      final session =
          Session(
              CallOptions(
                callId: 'ending',
                type: CallType.kVoice,
                dir: CallDirection.kIncoming,
                localPartyId: 'local',
                voip: calls.voip,
                room: room,
                iceServers: [],
              ),
            )
            ..setCallState(CallState.kRinging)
            ..cleanup = cleanup;
      final incoming = DirectCall(session, () {}, (_) {});
      calls.directInvitations.add(incoming);
      var finished = false;
      final accepting = calls
          .acceptDirect(incoming)
          .then((_) => finished = true);
      Future<void>? ending;
      try {
        await entered.future;
        ending = session.terminate(
          CallParty.kRemote,
          CallErrorCode.userHangup,
          true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(session.state, CallState.kEnded);
        expect(
          finished,
          isTrue,
          reason: 'Native disposal must not hold the cancelled acceptance',
        );
        expect(session.answers, 0);
        expect(session.hangups, 0);
      } finally {
        cleanup.complete();
        await ending;
        await calls.end();
        media.complete();
        await accepting;
        await incoming.close();
        await calls.close();
        await client.dispose();
      }
    },
  );
}
