import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/call_probe.dart';
import 'call_devices_test.dart' show DeviceClient, DeviceRoom;
import 'call_window_test.dart' show WindowDatabase;

Event _ended(Room room, String session, {String sender = '@peer:local'}) =>
    Event.fromJson({
      'type': EventTypes.Message,
      'event_id': r'$cancel',
      'sender': sender,
      'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
      'content': {
        'msgtype': 'dev.voicechat.call',
        'session': session,
        'action': 'end',
      },
    }, room);

class _ConnectedProbe extends CallProbe {
  _ConnectedProbe(Room room, String session)
    : super(
        chat: room,
        session: session,
        tokenUrl: 'http://localhost',
        livekitUrl: 'ws://localhost',
        status: (_) {},
      );
  @override
  Duration get duration => const Duration(seconds: 1);
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

  for (final stage in ['push', 'media']) {
    test(
      'Initiator cancellation releases group acceptance during $stage',
      () async {
        final entered = Completer<void>();
        final push = Completer<http.Response>();
        final media = Completer<void>();
        final client = Client(
          'group-accept-cancel',
          database: WindowDatabase(),
          httpClient: MockClient((_) {
            if (stage == 'push') {
              entered.complete();
              return push.future;
            }
            return Future.value(http.Response('{}', 200));
          }),
        );
        final room = DeviceRoom(client);
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
        final invitation = CallInvitation(
          room,
          'a' * 32,
          '@peer:local',
          DateTime.now(),
        );
        calls.invitations[invitation.session] = invitation;
        var finished = false;
        final accepting = calls
            .start(room, invitation: invitation)
            .then((_) => finished = true);
        try {
          await entered.future;
          calls.receive(_ended(room, invitation.session));
          await Future<void>.delayed(Duration.zero);
          expect(calls.invitations, isEmpty);
          expect(
            finished,
            isTrue,
            reason:
                'A cancelled invitation must release the slot before platform/network completion',
          );
          expect(calls.canHandleNewCall, isTrue);
          expect(calls.active, isNull);
        } finally {
          await calls.end();
          if (!push.isCompleted) push.complete(http.Response('{}', 200));
          if (!media.isCompleted) media.complete();
          await accepting;
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  for (final foreign in ['room', 'sender', 'session']) {
    test('Foreign $foreign cannot cancel a pending group acceptance', () async {
      final entered = Completer<void>(), media = Completer<void>();
      final client = Client(
        'group-scope',
        database: WindowDatabase(),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final room = DeviceRoom(client);
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
      final invitation = CallInvitation(
        room,
        'a' * 32,
        '@peer:local',
        DateTime.now(),
      );
      calls.invitations[invitation.session] = invitation;
      var finished = false;
      final accepting = calls
          .start(room, invitation: invitation)
          .then((_) => finished = true);
      try {
        await entered.future;
        calls.receive(
          _ended(
            foreign == 'room' ? DeviceRoom(client, id: '!other:local') : room,
            foreign == 'session' ? 'b' * 32 : invitation.session,
            sender: foreign == 'sender' ? '@other:local' : invitation.sender,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        expect(calls.starting, isTrue);
        expect(calls.invitations[invitation.session], same(invitation));
      } finally {
        await calls.end();
        media.complete();
        await accepting;
        await calls.close();
        await client.dispose();
      }
    });
  }

  for (final stale in [
    'removed',
    'expired',
    'different_room',
    'different_sender',
    'answered',
    'not_joined',
    'closed',
  ]) {
    test(
      'Stale $stale group acceptance does not request push or media',
      () async {
        var requests = 0, captures = 0;
        final client = Client(
          'group-stale',
          database: WindowDatabase(),
          httpClient: MockClient((request) async {
            if (request.url.path == '/push/call' &&
                jsonDecode(request.body)['action'] == 'accept') {
              requests++;
            }
            return http.Response('{}', 200);
          }),
        );
        final room = DeviceRoom(client);
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          (_) {},
          beforeMedia: () async {
            captures++;
            throw StateError('Must not prepare stale media');
          },
        );
        final invitation = CallInvitation(
          room,
          'a' * 32,
          '@peer:local',
          DateTime.now().subtract(
            Duration(seconds: stale == 'expired' ? 46 : 0),
          ),
        );
        if (stale != 'removed') {
          calls.invitations[invitation.session] = stale == 'different_sender'
              ? CallInvitation(
                  room,
                  invitation.session,
                  '@other:local',
                  DateTime.now(),
                )
              : invitation;
        }
        if (stale == 'closed') {
          await calls.close();
        }
        if (stale == 'answered') {
          calls.devices.handled[calls.devices.key(
                room.id,
                invitation.session,
              )] =
              DateTime.now();
        }
        if (stale == 'not_joined') room.membership = Membership.leave;
        try {
          await calls.start(
            stale == 'different_room'
                ? DeviceRoom(client, id: '!other:local')
                : room,
            invitation: invitation,
          );
          expect(requests, 0);
          expect(captures, 0);
          expect(calls.starting, isFalse);
          expect(calls.active, isNull);
        } finally {
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  test(
    'Expiry releases an accepted group invitation before the preparation deadline',
    () async {
      final entered = Completer<void>(), media = Completer<void>();
      final client = Client(
        'group-expiry',
        database: WindowDatabase(),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final room = DeviceRoom(client);
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
      final invitation = CallInvitation(
        room,
        'a' * 32,
        '@peer:local',
        DateTime.now().subtract(const Duration(seconds: 44)),
      );
      calls.invitations[invitation.session] = invitation;
      final accepting = calls.start(room, invitation: invitation);
      try {
        await entered.future;
        await accepting.timeout(const Duration(seconds: 7));
        expect(calls.invitations, isEmpty);
        expect(calls.canHandleNewCall, isTrue);
        expect(calls.active, isNull);
        expect(calls.dialError, isNull);
      } finally {
        await calls.end();
        media.complete();
        await accepting;
        await calls.close();
        await client.dispose();
      }
    },
  );

  for (final reason in ['verified_device', 'unverified_device', 'membership']) {
    test('Pending group acceptance follows $reason authorization', () async {
      final entered = Completer<void>(), media = Completer<void>();
      final client = DeviceClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final room = DeviceRoom(client);
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
      final invitation = CallInvitation(
        room,
        'a' * 32,
        '@peer:local',
        DateTime.now(),
      );
      calls.invitations[invitation.session] = invitation;
      var finished = false;
      final accepting = calls
          .start(room, invitation: invitation)
          .then((_) => finished = true);
      try {
        await entered.future;
        if (reason == 'membership') {
          room.membership = Membership.leave;
          calls.devices.changed();
        } else {
          client.trusted.directVerified = reason == 'verified_device';
          calls.devices.receive(
            ToDeviceEvent(
              sender: client.userID,
              type: 'dev.voicechat.call_device',
              encryptedContent: {'sender_key': 'trusted'},
              content: {
                'room_id': room.id,
                'session': invitation.session,
                'device': 'PHONE',
                'active': true,
                'sent_at': DateTime.now().millisecondsSinceEpoch,
              },
            ),
          );
        }
        await Future<void>.delayed(Duration.zero);
        final cancelled = reason != 'unverified_device';
        expect(finished, cancelled);
        expect(calls.canHandleNewCall, cancelled);
        expect(calls.active, isNull);
      } finally {
        await calls.end();
        media.complete();
        await accepting;
        await calls.close();
        await client.dispose();
      }
    });
  }

  for (final result in ['accepted', 'rejected', 'failed']) {
    test(
      'A late $result old group response preserves the next acceptance',
      () async {
        final entered = Completer<void>(), nextEntered = Completer<void>();
        final push = Completer<http.Response>(), media = Completer<void>();
        final reports = <String>[];
        var requests = 0, preparations = 0;
        final client = Client(
          'group-retry',
          database: WindowDatabase(),
          httpClient: MockClient((_) {
            if (++requests == 1) {
              entered.complete();
              return push.future;
            }
            return Future.value(http.Response('{}', 200));
          }),
        );
        final room = DeviceRoom(client);
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          reports.add,
          beforeMedia: () {
            preparations++;
            nextEntered.complete();
            return media.future;
          },
        );
        final first = CallInvitation(
          room,
          'a' * 32,
          '@peer:local',
          DateTime.now(),
        );
        calls.invitations[first.session] = first;
        final accepting = calls.start(room, invitation: first);
        Future<void>? next;
        var nextFinished = false;
        try {
          await entered.future;
          calls.receive(_ended(room, first.session));
          await accepting.timeout(const Duration(seconds: 1));
          final second = CallInvitation(
            room,
            'b' * 32,
            '@peer:local',
            DateTime.now(),
          );
          calls.invitations[second.session] = second;
          next = calls
              .start(room, invitation: second)
              .then((_) => nextFinished = true);
          await nextEntered.future;
          calls.receive(_ended(room, first.session));
          if (result == 'failed') {
            push.completeError(StateError('Synthetic old control failure'));
          } else {
            push.complete(
              http.Response(
                result == 'rejected' ? '{"error":"call_ended"}' : '{}',
                result == 'rejected' ? 403 : 200,
              ),
            );
          }
          await Future<void>.delayed(Duration.zero);
          expect(nextFinished, isFalse);
          expect(calls.starting, isTrue);
          expect(calls.invitations[second.session], same(second));
          expect(preparations, 1);
          expect(reports, isEmpty);
          calls.receive(_ended(room, second.session));
          await next.timeout(const Duration(seconds: 1));
          expect(calls.canHandleNewCall, isTrue);
        } finally {
          await calls.end();
          if (!push.isCompleted) push.complete(http.Response('{}', 200));
          media.complete();
          await accepting;
          await next;
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  for (final owner in ['same', 'other_session', 'other_room']) {
    test(
      'Cancelling an invitation closes only its pending group transport: $owner',
      () async {
        final entered = Completer<void>(), media = Completer<void>();
        final client = Client(
          'group-transport-owner',
          database: WindowDatabase(),
          httpClient: MockClient((_) async => http.Response('{}', 200)),
        );
        final room = DeviceRoom(client);
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
        final invitation = CallInvitation(
          room,
          'a' * 32,
          '@peer:local',
          DateTime.now(),
        );
        calls.invitations[invitation.session] = invitation;
        final accepting = calls.start(room, invitation: invitation);
        final transport = CallProbe(
          chat: owner == 'other_room'
              ? DeviceRoom(client, id: '!other:local')
              : room,
          session: owner == 'other_session' ? 'b' * 32 : invitation.session,
          tokenUrl: 'http://localhost',
          livekitUrl: 'ws://localhost',
          status: (_) {},
        );
        try {
          await entered.future;
          calls.active = transport;
          calls.receive(_ended(room, invitation.session));
          await accepting.timeout(const Duration(seconds: 1));
          expect(transport.isClosed, owner == 'same');
          expect(calls.active, same(transport));
        } finally {
          await calls.end();
          media.complete();
          await accepting;
          await transport.close();
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  for (final stage in ['push', 'media']) {
    test(
      'An invitation expiring during $stage cannot reach the next media phase',
      () async {
        final entered = Completer<void>(), media = Completer<void>();
        final push = Completer<http.Response>();
        var preparations = 0;
        final client = Client(
          'group-expiry-boundary',
          database: WindowDatabase(),
          httpClient: MockClient((_) {
            if (stage == 'push') {
              entered.complete();
              return push.future;
            }
            return Future.value(http.Response('{}', 200));
          }),
        );
        final room = DeviceRoom(client);
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          (_) {},
          beforeMedia: () async {
            preparations++;
            if (stage == 'push') {
              throw StateError('Expired invitation reached media preparation');
            }
            entered.complete();
            await media.future;
          },
        );
        final invitation = CallInvitation(
          room,
          'a' * 32,
          '@peer:local',
          DateTime.now().subtract(const Duration(seconds: 44)),
        );
        calls.invitations[invitation.session] = invitation;
        final accepting = calls
            .start(room, invitation: invitation)
            .then<Object?>((_) => null, onError: (Object error) => error);
        try {
          await entered.future;
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          if (stage == 'push') {
            push.complete(http.Response('{}', 200));
          } else {
            media.complete();
          }
          expect(await accepting, isNull);
          expect(preparations, stage == 'push' ? 0 : 1);
          expect(calls.active, isNull);
          expect(calls.starting, isFalse);
        } finally {
          await calls.end();
          if (!push.isCompleted) push.complete(http.Response('{}', 200));
          if (!media.isCompleted) media.complete();
          await accepting;
          await calls.close();
          await client.dispose();
        }
      },
    );
  }

  test(
    'Invitation expiry cannot end group media that has already connected',
    () async {
      final entered = Completer<void>(), media = Completer<void>();
      final client = Client(
        'group-connected-expiry',
        database: WindowDatabase(),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final room = DeviceRoom(client);
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
      final invitation = CallInvitation(
        room,
        'a' * 32,
        '@peer:local',
        DateTime.now().subtract(const Duration(seconds: 44)),
      );
      calls.invitations[invitation.session] = invitation;
      var finished = false;
      final accepting = calls
          .start(room, invitation: invitation)
          .then((_) => finished = true);
      final connected = _ConnectedProbe(room, invitation.session);
      try {
        await entered.future;
        calls.active = connected;
        await Future<void>.delayed(const Duration(milliseconds: 5100));
        expect(calls.invitations, isEmpty);
        expect(connected.isClosed, isFalse);
        expect(finished, isFalse);
        expect(calls.dialError, isNull);
      } finally {
        await calls.end();
        media.complete();
        await accepting;
        await connected.close();
        await calls.close();
        await client.dispose();
      }
    },
  );

  test(
    'An invitation joins existing admission instead of recreating an ended call',
    () async {
      final client = Client(
        'group-existing-admission',
        database: WindowDatabase(),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final room = DeviceRoom(client);
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
      );
      final invitation = CallInvitation(
        room,
        'a' * 32,
        '@peer:local',
        DateTime.now(),
      );
      calls.invitations[invitation.session] = invitation;
      CallProbe? created;
      calls.addListener(() {
        if (calls.active case final CallProbe call) created = call;
      });
      try {
        // Stop at native initialization: this test checks the admission contract,
        // while the real Matrix/SFU UI scenario verifies the media path separately.
        await expectLater(
          calls.start(room, invitation: invitation),
          throwsA(isA<MissingPluginException>()),
        );
        expect(created, isNotNull);
        expect(created!.joinExisting, isTrue);
      } finally {
        await calls.close();
        await client.dispose();
      }
    },
  );
}
