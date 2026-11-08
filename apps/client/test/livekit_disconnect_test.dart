// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/engine.dart';
import 'package:livekit_client/src/internal/events.dart';
import 'package:livekit_client/src/managers/event.dart';

class DisconnectEngine extends Engine {
  DisconnectEngine()
    : super(
        connectOptions: const lk.ConnectOptions(),
        roomOptions: const lk.RoomOptions(),
      );

  int disconnects = 0;
  bool pendingReconnect = false;
  bool emitsEvent = true;
  @override
  bool get isClosed => false;
  @override
  bool get isPendingReconnect => pendingReconnect;
  @override
  lk.ConnectionState get connectionState => lk.ConnectionState.connected;

  @override
  Future<void> disconnect({
    lk.DisconnectReason reason = lk.DisconnectReason.clientInitiated,
  }) async {
    disconnects++;
    if (emitsEvent) events.emit(EngineDisconnectedEvent(reason: reason));
    // A fast server reply can arrive before sendLeave's future completes.
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> cleanUp() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Room observes disconnect received before the leave future ends',
    () async {
      final engine = DisconnectEngine();
      final room = lk.Room(engine: engine);
      addTearDown(room.dispose);
      await expectLater(
        room.disconnect().timeout(const Duration(seconds: 1)),
        completes,
      );
      expect(engine.disconnects, 1);
    },
  );

  test(
    'Pending reconnect cancellation does not await a leave acknowledgement',
    () async {
      final engine = DisconnectEngine()
        ..pendingReconnect = true
        ..emitsEvent = false;
      final room = lk.Room(engine: engine);
      addTearDown(room.dispose);
      await room.disconnect().timeout(const Duration(seconds: 1));
      expect(engine.disconnects, 1);
    },
  );

  test('An existing event wait still works without a trigger', () async {
    final emitter = EventsEmitter<int>();
    final listener = EventsListener(emitter);
    addTearDown(emitter.dispose);
    addTearDown(listener.dispose);
    final result = listener.waitFor<int>(duration: const Duration(seconds: 1));
    emitter.emit(7);
    expect(await result, 7);
    expect(listener.listeners, isEmpty);
  });

  test(
    'A failed trigger removes its waiter and preserves the original error',
    () async {
      final emitter = EventsEmitter<int>();
      final listener = EventsListener(emitter);
      addTearDown(emitter.dispose);
      addTearDown(listener.dispose);
      final error = StateError('leave send failed');
      await expectLater(
        listener.waitFor<int>(
          duration: const Duration(seconds: 1),
          trigger: () => throw error,
        ),
        throwsA(same(error)),
      );
      expect(listener.listeners, isEmpty);
    },
  );

  test(
    'A missing acknowledgement still times out and removes its waiter',
    () async {
      final emitter = EventsEmitter<int>();
      final listener = EventsListener(emitter);
      addTearDown(emitter.dispose);
      addTearDown(listener.dispose);
      await expectLater(
        listener.waitFor<int>(
          duration: const Duration(milliseconds: 1),
          trigger: () {},
        ),
        throwsA(isA<lk.TimeoutException>()),
      );
      expect(listener.listeners, isEmpty);
    },
  );
}
