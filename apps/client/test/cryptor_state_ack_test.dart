// SDK contract tests with controlled native replies; no media or network.
// ignore_for_file: implementation_imports
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:flutter_webrtc/src/native/rtc_rtp_sender_impl.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/e2ee/e2ee_manager.dart';
import 'package:livekit_client/src/managers/event.dart';

class _Keys implements rtc.KeyProvider {
  @override
  String get id => 'fixture-provider';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Participant implements lk.LocalParticipant {
  @override
  String get identity => 'alice';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Room implements lk.Room {
  @override
  final events = EventsEmitter<lk.RoomEvent>();
  @override
  lk.LocalParticipant get localParticipant => _Participant();
  @override
  bool get isDisposed => false;
  @override
  EventsListener<lk.RoomEvent> createListener({bool synchronized = false}) =>
      EventsListener(events, synchronized: synchronized);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final room = _Room();
  final enabled = <String, bool>{};
  final indices = <String, int>{};
  final eventChannels = <MethodChannel>[];
  late final E2EEManager manager;
  bool rejectIndex = false, rejectEnabled = false;
  Completer<bool>? pendingDisable;

  Future<void> initialize() async {
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        final args = call.arguments as Map? ?? {};
        switch (call.method) {
          case 'initialize':
            return null;
          case 'createDataPacketCryptor':
            return {'dataCryptorId': 'fixture-data'};
          case 'frameCryptorFactoryCreateFrameCryptor':
            final id = 'cryptor-${eventChannels.length}';
            final channel = MethodChannel('FlutterWebRTC/frameCryptorEvent$id');
            eventChannels.add(channel);
            messenger.setMockMethodCallHandler(channel, (_) async => null);
            enabled[id] = false;
            indices[id] = 0;
            return {'frameCryptorId': id};
          case 'frameCryptorSetEnabled':
            final desired = args['enabled'] as bool;
            final pending = pendingDisable;
            if (!desired && pending != null) {
              pendingDisable = null;
              if (!await pending.future) return {'result': false};
            }
            if (rejectEnabled) return {'result': false};
            enabled[args['frameCryptorId'] as String] = desired;
            return {'result': true};
          case 'frameCryptorSetKeyIndex':
            if (rejectIndex) return {'result': false};
            indices[args['frameCryptorId'] as String] = args['keyIndex'] as int;
            return {'result': true};
          case 'frameCryptorGetKeyIndex':
            return {'keyIndex': indices[args['frameCryptorId']]};
          case 'frameCryptorDispose':
          case 'dataPacketCryptorDispose':
            return {'result': true};
          default:
            throw StateError('Unexpected fixture RPC: ${call.method}');
        }
      },
    );
    manager = E2EEManager(
      lk.BaseKeyProvider(
        _Keys(),
        rtc.KeyProviderOptions(
          sharedKey: false,
          ratchetSalt: Uint8List(32),
          ratchetWindowSize: 16,
        ),
      ),
    );
    await manager.setup(room);
    await prepare('first');
  }

  Future<void> prepare(String id) => manager.prepareLocalSender(
    RTCRtpSenderNative.fromMap({
      'senderId': id,
      'track': <String, Object>{},
      'ownsTrack': false,
      'rtpParameters': {
        'transactionId': 'fixture',
        'rtcp': {'cname': 'fixture', 'reducedSize': true},
        'encodings': [],
        'codecs': [],
        'headerExtensions': [],
      },
    }, peerConnectionId: 'fixture-peer'),
  );

  Future<void> close() async {
    await manager.dispose();
    await room.events.streamCtrl.close();
    for (final channel in eventChannels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      null,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() async {
    fixture = _Fixture();
    await fixture.initialize();
  });
  tearDown(() => fixture.close());

  test('Public key-index update rejects a false native reply', () async {
    fixture.rejectIndex = true;
    await expectLater(
      fixture.manager.setKeyIndex(1, participantIdentity: 'alice'),
      throwsStateError,
    );
    expect(await fixture.manager.getKeyIndex('alice'), 0);
  });

  test('Public encryption toggle rejects a false native reply', () async {
    fixture.rejectEnabled = true;
    await expectLater(fixture.manager.setEnabled(false), throwsStateError);
  });

  test('Rejected toggle preserves the state used for a new sender', () async {
    fixture.rejectEnabled = true;
    try {
      await fixture.manager.setEnabled(false);
    } catch (_) {}
    fixture.rejectEnabled = false;
    await fixture.prepare('second');
    expect(fixture.enabled.values, everyElement(isTrue));
  });

  test(
    'A pending toggle does not configure a concurrent sender as confirmed',
    () async {
      final reply = Completer<bool>();
      fixture.pendingDisable = reply;
      final pending = expectLater(
        fixture.manager.setEnabled(false),
        throwsStateError,
      );
      try {
        await fixture.prepare('second');
        expect(fixture.enabled.values, everyElement(isTrue));
      } finally {
        reply.complete(false);
        await pending;
      }
    },
  );

  test(
    'A confirmed toggle includes a sender created while the reply was pending',
    () async {
      final reply = Completer<bool>();
      fixture.pendingDisable = reply;
      final pending = fixture.manager.setEnabled(false);
      try {
        await fixture.prepare('second');
        expect(fixture.enabled.values, everyElement(isTrue));
      } finally {
        reply.complete(true);
        await pending;
      }
      expect(fixture.enabled.values, everyElement(isFalse));
      await fixture.prepare('third');
      expect(fixture.enabled.values, everyElement(isFalse));
    },
  );

  test(
    'Concurrent toggles preserve their order and future sender state',
    () async {
      final reply = Completer<bool>();
      fixture.pendingDisable = reply;
      final disable = fixture.manager.setEnabled(false);
      final enable = fixture.manager.setEnabled(true);
      reply.complete(true);
      await Future.wait([disable, enable]);
      await fixture.prepare('second');
      expect(fixture.enabled.values, everyElement(isTrue));
    },
  );

  test(
    'Successful native updates and future sender state still work',
    () async {
      await fixture.manager.setKeyIndex(1, participantIdentity: 'alice');
      expect(await fixture.manager.getKeyIndex('alice'), 1);
      await fixture.manager.setEnabled(false);
      await fixture.prepare('second');
      expect(fixture.enabled.values, everyElement(isFalse));
      await fixture.manager.setEnabled(true);
      expect(fixture.enabled.values, everyElement(isTrue));
    },
  );
}
