// ignore_for_file: invalid_use_of_internal_member, implementation_imports, avoid_print
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/types/internal.dart';
import 'package:voicechat_probe/route_config.dart';
import 'package:voicechat_probe/route_coordinator.dart';
import 'package:voicechat_probe/route_transport.dart';
import 'package:voicechat_probe/routed_livekit_engine.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native LiveKit resumes through C after losing B', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final config = RouteConfig.parse(
        const String.fromEnvironment('ROUTE_CONFIG'),
      );
      final coordinator = RouteCoordinator(config);
      final network = RouteTransport(
        origin: config.canonicalOrigin,
        routes: config.edges.map((e) => e.origin).toList(),
        inner: http.Client(),
        coordinator: coordinator,
      );
      // Use B for the initial connection, regardless of loopback timing noise.
      final raw =
          jsonDecode(const String.fromEnvironment('ROUTE_CONFIG'))
              as Map<String, dynamic>;
      raw['edges'] = [raw['edges'][0]];
      final initial = RouteCoordinator(RouteConfig.parse(jsonEncode(raw)));
      final initialNetwork = RouteTransport(
        origin: config.canonicalOrigin,
        routes: config.edges.map((e) => e.origin).toList(),
        inner: http.Client(),
        coordinator: initial,
      );
      await initial.refresh();
      var refreshes = 0;
      const options = lk.ConnectOptions(
        autoSubscribe: false,
        rtcConfiguration: lk.RTCConfiguration(
          // This fixture tests signaling/ICE state, not TURN reachability. Direct
          // SFU candidates use the loopback-published UDP range; relay has its own probe.
          iceServers: [
            lk.RTCIceServer(
              urls: ['turn:localhost:9?transport=tcp'],
              username: 'temporary',
              credential: 'temporary',
            ),
          ],
        ),
      );
      final encryption = await lk.E2EEOptions.sharedKey(
        'local-probe-key-never-used-in-production',
      );
      final roomOptions = lk.RoomOptions(encryption: encryption);
      final engine = RoutedLiveKitEngine(
        canRecover: () => true,
        network: network,
        canonicalUrl: 'ws://localhost:9',
        roomOptions: roomOptions,
        loadOptions: () async {
          refreshes++;
          return options;
        },
      );
      final alice = lk.Room(roomOptions: roomOptions, engine: engine);
      final bob = lk.Room(
        roomOptions: lk.RoomOptions(
          encryption: await lk.E2EEOptions.sharedKey(
            'local-probe-key-never-used-in-production',
          ),
        ),
      );
      final events = alice.createListener();
      final receiver = bob.createListener();
      var reconnected = Completer<void>();
      final deliveries = <String, Completer<void>>{};
      receiver.on<lk.DataReceivedEvent>((event) {
        deliveries[utf8.decode(event.data)]?.complete();
      });
      events.on<lk.RoomReconnectedEvent>((_) {
        if (!reconnected.isCompleted) reconnected.complete();
      });
      try {
        await bob.connect(
          config.edges[1].origin.replace(scheme: 'ws').toString(),
          const String.fromEnvironment('LIVEKIT_TEST_BOB'),
        );
        await alice.connect(
          initialNetwork.websocketUrl('ws://localhost:9'),
          const String.fromEnvironment('LIVEKIT_TEST_ALICE'),
          connectOptions: options,
        );
        final sid = alice.localParticipant!.sid;
        Future<void> deliver(String value) async {
          final received = deliveries[value] = Completer<void>();
          await alice.localParticipant!.publishData(
            utf8.encode(value),
            reliable: true,
          );
          await received.future.timeout(const Duration(seconds: 10));
        }

        await deliver('before-failure');
        final clock = Stopwatch()..start();
        final response = await http.post(
          Uri.parse(
            '${const String.fromEnvironment('ROUTE_TEST_FAULTS')}/stop/b',
          ),
          headers: {
            'Authorization':
                'Bearer ${const String.fromEnvironment('ROUTE_TEST_FAULT_SECRET')}',
          },
        );
        expect(response.statusCode, 204);
        expect(
          (await http.get(
            config.edges.first.origin.resolve('/health/route'),
          )).statusCode,
          200,
        );
        await reconnected.future.timeout(const Duration(seconds: 25));
        final recoveryMs = clock.elapsedMilliseconds;
        expect(coordinator.route(RouteService.signaling)!.id, 'c');
        expect(Uri.parse(engine.url!).port, config.edges[1].origin.port);
        expect(alice.localParticipant!.sid, sid);
        expect(
          identical(
            alice.roomOptions.encryption!.keyProvider,
            encryption.keyProvider,
          ),
          isTrue,
        );
        expect(refreshes, greaterThan(0));
        await deliver('after-failure');
        // Rebuild both peer connections through the SDK's second recovery path.
        reconnected = Completer<void>();
        final restartClock = Stopwatch()..start();
        engine.fullReconnectOnNext = true;
        await engine.attemptReconnect(
          ClientDisconnectReason.peerConnectionFailed,
        );
        await reconnected.future.timeout(const Duration(seconds: 25));
        final restartMs = restartClock.elapsedMilliseconds;
        expect(
          identical(
            alice.roomOptions.encryption!.keyProvider,
            encryption.keyProvider,
          ),
          isTrue,
        );
        expect(refreshes, greaterThanOrEqualTo(2));
        await deliver('after-full-restart');
        print(
          'LIVEKIT_ROUTE_PROOF ${jsonEncode({'recovery_ms': recoveryMs, 'turn_refreshes': refreshes, 'same_participant_on_resume': true, 'data_before_after': true, 'full_restart_ms': restartMs, 'data_after_full_restart': true})}',
        );
        expect(recoveryMs, lessThanOrEqualTo(15000));
      } finally {
        await receiver.dispose();
        await events.dispose();
        await alice.dispose();
        await bob.dispose();
        initialNetwork.close();
        network.close();
        initial.close();
        coordinator.close();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
