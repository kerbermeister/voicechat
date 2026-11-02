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
import 'package:voicechat_probe/user_action_error.dart';
import 'call_window_test.dart' show CallRoom, WindowDatabase;
import 'direct_call_protocol_test.dart' show ProtocolVoip, Session;

class _Incoming extends DirectCall {
  _Incoming(CallSession session) : super(session, () {}, (_) {});
  int answers = 0;
  @override
  Future<void> answer() async {
    if (!isClosed) answers++;
  }
}

_Incoming _incoming(Client client, String id) => _Incoming(
  Session(
    CallOptions(
      callId: id,
      type: CallType.kVoice,
      dir: CallDirection.kIncoming,
      localPartyId: 'local',
      voip: ProtocolVoip(),
      room: CallRoom(client),
      iceServers: [],
    ),
  ),
);

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

  for (final stage in ['push', 'media', 'push_rejected', 'push_failed']) {
    test(
      'Cancelled incoming acceptance cannot replace a new owner after $stage',
      () async {
        final entered = Completer<void>();
        final push = Completer<http.Response>();
        final media = Completer<void>();
        final reports = <String>[];
        final client = Client(
          'incoming-handoff',
          database: WindowDatabase(),
          httpClient: MockClient((request) async {
            if (stage.startsWith('push')) {
              entered.complete();
              return push.future;
            }
            return http.Response('{}', 200);
          }),
        );
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          reports.add,
          beforeMedia: () async {
            if (stage == 'media') {
              entered.complete();
              await media.future;
            }
          },
        );
        final old = _incoming(client, 'old');
        final newer = _incoming(client, 'new');
        calls.directInvitations.add(old);
        final accepting = calls.acceptDirect(old);
        try {
          await entered.future;
          // The old caller cancels; another call acquires the now free slot.
          await old.close();
          calls.directInvitations.remove(old);
          calls.active = newer;
          if (stage == 'push_rejected') {
            push.complete(http.Response('{"error":"call_ended"}', 403));
          } else if (stage == 'push_failed') {
            push.completeError(StateError('Synthetic control disconnect'));
          } else if (stage == 'push') {
            push.complete(http.Response('{}', 200));
          } else {
            media.complete();
          }
          await accepting;
          expect(calls.active, same(newer));
          expect(newer.isClosed, isFalse);
          expect(old.answers, 0);
          expect(reports, isEmpty);
        } finally {
          if (!push.isCompleted) push.complete(http.Response('{}', 200));
          if (!media.isCompleted) media.complete();
          await accepting;
          await calls.close();
          await old.close();
          await newer.close();
          await client.dispose();
        }
      },
    );
  }

  for (final ending in ['local_end', 'remote_end', 'controller_close']) {
    test('Incoming preparation finishes promptly on $ending', () async {
      final client = Client(
        'incoming-cancel',
        database: WindowDatabase(),
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      );
      final gate = Completer<void>(), entered = Completer<void>();
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
        beforeMedia: () {
          entered.complete();
          return gate.future;
        },
      );
      final call = _incoming(client, 'pending');
      calls.directInvitations.add(call);
      var finished = false;
      final accepting = calls.acceptDirect(call).then((_) => finished = true);
      try {
        await entered.future;
        if (ending == 'local_end') {
          await calls.end();
        } else if (ending == 'remote_end') {
          await call.close();
          await calls.handleCallEnded(call.call);
        } else {
          await calls.close();
        }
        await Future<void>.delayed(Duration.zero);
        expect(finished, isTrue);
        expect(call.isClosed, isTrue);
        expect(call.answers, 0);
      } finally {
        gate.complete();
        await accepting;
        await calls.close();
        await call.close();
        await client.dispose();
      }
    });
  }

  test(
    'Incoming acceptance reserves its slot and ignores duplicate acceptance',
    () async {
      final entered = Completer<void>(), ack = Completer<http.Response>();
      var requests = 0;
      final client = Client(
        'incoming-reservation',
        database: WindowDatabase(),
        httpClient: MockClient((_) {
          requests++;
          entered.complete();
          return ack.future;
        }),
      );
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
      );
      final first = _incoming(client, 'first'),
          second = _incoming(client, 'second');
      calls.directInvitations.addAll([first, second]);
      final accepting = calls.acceptDirect(first);
      try {
        await entered.future;
        expect(calls.active, same(first));
        expect(calls.canHandleNewCall, isFalse);
        await calls.acceptDirect(first);
        await expectLater(
          calls.acceptDirect(second),
          throwsA(isA<UserActionError>()),
        );
        expect(requests, 1);
        ack.complete(http.Response('{}', 200));
        await accepting;
        expect(first.answers, 1);
        expect(second.answers, 0);
        expect(calls.devices.isAccepted(first), isTrue);
      } finally {
        if (!ack.isCompleted) ack.complete(http.Response('{}', 200));
        await accepting;
        await calls.close();
        await first.close();
        await second.close();
        await client.dispose();
      }
    },
  );

  test('An incoming acceptance cannot steal an outgoing preparation', () async {
    final entered = Completer<void>(), media = Completer<void>();
    var requests = 0;
    final client = Client(
      'outgoing-reservation',
      database: WindowDatabase(),
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
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
    final call = _incoming(client, 'incoming');
    calls.directInvitations.add(call);
    final starting = calls.start(CallRoom(client));
    try {
      await entered.future;
      await expectLater(
        calls.acceptDirect(call),
        throwsA(isA<UserActionError>()),
      );
      expect(requests, 0);
      expect(call.answers, 0);
      await calls.end();
      await starting;
    } finally {
      if (!media.isCompleted) media.complete();
      await starting;
      await calls.close();
      await call.close();
      await client.dispose();
    }
  });

  test('An old call ending cannot cancel the newer acceptance', () async {
    final entered = Completer<void>(), media = Completer<void>();
    final client = Client(
      'late-incoming-end',
      database: WindowDatabase(),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
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
    final old = _incoming(client, 'old'), newer = _incoming(client, 'new');
    calls.directInvitations.add(newer);
    var finished = false;
    final accepting = calls.acceptDirect(newer).then((_) => finished = true);
    try {
      await entered.future;
      await old.close();
      await calls.handleCallEnded(old.call);
      expect(finished, isFalse);
      expect(calls.active, same(newer));
      expect(newer.isClosed, isFalse);
      media.complete();
      await accepting;
      expect(newer.answers, 1);
      expect(calls.devices.isAccepted(newer), isTrue);
    } finally {
      if (!media.isCompleted) media.complete();
      await accepting;
      await calls.close();
      await old.close();
      await newer.close();
      await client.dispose();
    }
  });

  // Exercise the real HTTP stream wrapper and its subsequent preparation bound.
  test('Incoming media preparation expires without answering', () async {
    final client = Client(
      'incoming-deadline',
      database: WindowDatabase(),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    final media = Completer<void>();
    final calls = CallController(
      client,
      'http://localhost',
      'ws://localhost',
      (_) {},
      beforeMedia: () => media.future,
    );
    final call = _incoming(client, 'deadline');
    calls.directInvitations.add(call);
    final accepting = calls.acceptDirect(call);
    try {
      await expectLater(accepting, throwsA(isA<TimeoutException>()));
      expect(call.isClosed, isTrue);
      expect(call.answers, 0);
      expect(calls.devices.isAccepted(call), isFalse);
    } finally {
      media.complete();
      await calls.close();
      await call.close();
      await client.dispose();
    }
  }, timeout: const Timeout(Duration(seconds: 55)));
}
