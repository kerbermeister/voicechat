// Controller cancellation must finish even if a platform startup Future does not.
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/voip_id.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'call_window_test.dart' show CallRoom, WindowDatabase;
import 'direct_call_protocol_test.dart'
    show Delegate, ProtocolVoip, ProtocolStream, Session;

class _StartDelegate extends Delegate {
  final registered = Completer<void>();
  Completer<void>? listeners;
  final shown = <CallSession>[];
  @override
  Future<void> registerListeners(CallSession session) async {
    registered.complete();
    await listeners?.future;
  }

  @override
  Future<void> handleNewCall(CallSession session) async {
    shown.add(session);
  }
}

class _StartVoip extends VoIP {
  _StartVoip(super.client, super.delegate);
  Completer<List<Map<String, dynamic>>>? ice;
  int iceRequests = 0;
  final created = <Session>[];
  @override
  Future<List<Map<String, dynamic>>> getIceServers() async {
    iceRequests++;
    return await ice?.future ?? [];
  }

  @override
  CallSession createNewCall(CallOptions opts) {
    final session = Session(opts);
    calls[VoipId(roomId: opts.room.id, callId: opts.callId)] = session;
    created.add(session);
    return session;
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

  testWidgets('Unanswered preparation expires independently of peer ringing', (
    tester,
  ) async {
    final client = Client('preparation-deadline', database: WindowDatabase());
    final pending = Completer<void>();
    final calls = CallController(
      client,
      'http://localhost',
      'ws://localhost',
      (_) {},
      beforeMedia: () => pending.future,
    );
    var done = false;
    final starting = calls.start(CallRoom(client)).then((_) {
      done = true;
    });
    try {
      await tester.pump(const Duration(milliseconds: 44999));
      expect(done, isFalse);
      expect(calls.canHandleNewCall, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      await starting;
      expect(done, isTrue);
      expect(calls.starting, isFalse);
      expect(calls.canHandleNewCall, isTrue);
      expect(calls.dialError, contains('Не удалось подготовить звонок'));
      pending.complete();
      await tester.pump();
      expect(calls.starting, isFalse);
      expect(calls.active, isNull);
    } finally {
      if (!pending.isCompleted) pending.complete();
      await tester.runAsync(calls.close);
      await starting;
      await tester.runAsync(client.dispose);
    }
  });

  testWidgets('Preparation deadline cannot end an already connected call', (
    tester,
  ) async {
    final client = Client('connected-deadline', database: WindowDatabase());
    final pending = Completer<void>();
    final calls = CallController(
      client,
      'http://localhost',
      'ws://localhost',
      (_) {},
      beforeMedia: () => pending.future,
    );
    final starting = calls.start(CallRoom(client));
    final session = Session(
      CallOptions(
        callId: 'connected',
        type: CallType.kVoice,
        dir: CallDirection.kOutgoing,
        localPartyId: 'local',
        voip: ProtocolVoip(),
        room: CallRoom(client),
        iceServers: [],
      ),
    )..setCallState(CallState.kConnected);
    calls.active = DirectCall(session, () {}, (_) {});
    try {
      await tester.pump(const Duration(seconds: 45));
      expect(session.state, CallState.kConnected);
      expect(calls.dialError, isNull);
      await tester.runAsync(calls.end);
      await starting;
    } finally {
      if (!pending.isCompleted) pending.complete();
      await tester.runAsync(calls.close);
      await starting;
      await tester.runAsync(client.dispose);
    }
  });

  for (final scenario in [
    'entry',
    'turn',
    'turn_failure',
    'listeners',
    'capture',
    'normal',
  ]) {
    test('VoIP startup cancellation/failure scope: $scenario', () async {
      final client = Client('start-scope', database: WindowDatabase());
      final delegate = _StartDelegate();
      final voip = _StartVoip(client, delegate);
      final room = CallRoom(client);
      var cancelled = scenario == 'entry';
      if (scenario.startsWith('turn')) voip.ice = Completer();
      if (scenario == 'listeners') delegate.listeners = Completer();
      final stream = ProtocolStream();
      final operation = voip
          .inviteToCall(room, CallType.kVoice, isCancelled: () => cancelled)
          .then<Object?>((_) => null, onError: (Object e) => e);
      final replacement = VoipId(roomId: room.id, callId: 'replacement');
      try {
        if (scenario.startsWith('turn')) {
          await Future<void>.delayed(Duration.zero);
          if (scenario == 'turn_failure') {
            voip.ice!.completeError(StateError('Synthetic TURN outage'));
          } else {
            cancelled = true;
            voip.incomingCallRoomId[room.id] = replacement.callId;
            voip.currentCID = replacement;
            voip.ice!.complete([]);
          }
        } else if (scenario == 'listeners') {
          await delegate.registered.future;
          cancelled = true;
          delegate.listeners!.complete();
        } else if (scenario != 'entry') {
          await delegate.mediaDevices.requested.future;
          if (scenario == 'capture') {
            cancelled = true;
            await voip.created.single.hangup(reason: CallErrorCode.userHangup);
            voip.incomingCallRoomId[room.id] = replacement.callId;
            voip.currentCID = replacement;
          }
          delegate.mediaDevices.result.complete(stream);
        }
        final error = await operation;
        expect(error, scenario == 'normal' ? isNull : isStateError);
        if (scenario == 'normal') {
          expect(delegate.shown, [voip.created.single]);
          expect(voip.created.single.callHasEnded, isFalse);
        } else {
          expect(delegate.shown, isEmpty);
          if (scenario == 'entry') expect(voip.iceRequests, 0);
          if (['entry', 'turn', 'turn_failure'].contains(scenario)) {
            expect(voip.created, isEmpty);
          } else {
            expect(voip.created.single.callHasEnded, isTrue);
            expect(voip.calls, isEmpty);
          }
          if (scenario != 'capture') {
            expect(delegate.mediaDevices.requested.isCompleted, isFalse);
          } else {
            expect(stream.disposed, isTrue);
            expect(voip.created.single.captured, isEmpty);
          }
          if (scenario == 'turn' || scenario == 'capture') {
            expect(voip.currentCID, replacement);
            expect(voip.incomingCallRoomId[room.id], replacement.callId);
          } else {
            expect(voip.currentCID, isNull);
            expect(voip.incomingCallRoomId, isEmpty);
          }
        }
      } finally {
        if (voip.ice?.isCompleted == false) voip.ice!.complete([]);
        if (delegate.listeners?.isCompleted == false) {
          delegate.listeners!.complete();
        }
        if (!delegate.mediaDevices.result.isCompleted) {
          delegate.mediaDevices.result.complete(stream);
        }
        await operation;
        for (final call in voip.created) {
          await call.hangup(reason: CallErrorCode.userHangup);
        }
        await stream.dispose();
        await client.dispose();
      }
    });
  }

  test(
    'Cancel closes the registered outgoing session while capture is pending',
    () async {
      final client = Client('pending-capture', database: WindowDatabase());
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
      );
      final voip = ProtocolVoip();
      final session = Session(
        CallOptions(
          callId: 'pending',
          type: CallType.kVoice,
          dir: CallDirection.kOutgoing,
          localPartyId: 'local',
          voip: voip,
          room: CallRoom(client),
          iceServers: [],
        ),
      );
      final late = ProtocolStream();
      Future<void>? preparing;
      try {
        calls.starting = true;
        await calls.registerListeners(session);
        preparing = session.initOutboundCall(CallType.kVoice);
        await voip.delegate.mediaDevices.requested.future;
        await calls.end();
        expect(
          session.callHasEnded,
          isTrue,
          reason:
              'The UI cancel must fence the SDK before a late permission response',
        );
        voip.delegate.mediaDevices.result.complete(late);
        await preparing;
        expect(session.captured, isEmpty);
        expect(late.disposed, isTrue);
      } finally {
        if (!voip.delegate.mediaDevices.result.isCompleted) {
          voip.delegate.mediaDevices.result.complete(late);
        }
        await preparing;
        await calls.close();
        await session.cleanUp();
        await client.dispose();
      }
    },
  );

  test(
    'Cancel finishes startup and a late old result cannot reset its retry',
    () async {
      final client = Client('pending-start', database: WindowDatabase());
      final first = Completer<void>(), second = Completer<void>();
      var preparations = 0, firstDone = false, secondDone = false;
      final calls = CallController(
        client,
        'http://localhost',
        'ws://localhost',
        (_) {},
        beforeMedia: () => (++preparations == 1 ? first : second).future,
      );
      Future<void>? retry;
      final starting = calls.start(CallRoom(client)).then((_) {
        firstDone = true;
      });
      try {
        await Future<void>.delayed(Duration.zero);
        expect(calls.starting, isTrue);
        expect(calls.canHandleNewCall, isFalse);
        await calls.end();
        await Future<void>.delayed(Duration.zero);
        expect(
          firstDone,
          isTrue,
          reason:
              'Cancellation must release the caller, not await a platform Future forever',
        );
        retry = calls.start(CallRoom(client)).then((_) {
          secondDone = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(preparations, 2);
        first.complete();
        await starting;
        await Future<void>.delayed(Duration.zero);
        expect(
          calls.starting,
          isTrue,
          reason: 'Completion of the old operation must preserve the retry',
        );
        expect(secondDone, isFalse);
        await calls.end();
        await retry;
        expect(secondDone, isTrue);
      } finally {
        if (!first.isCompleted) first.complete();
        if (!second.isCompleted) second.complete();
        await starting;
        await retry;
        await calls.close();
        await client.dispose();
      }
    },
  );
}
