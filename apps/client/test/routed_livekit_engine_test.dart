// Exercise the pinned SDK's real resume/restart flow up to its signaling boundary.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/signal_client.dart';
import 'package:livekit_client/src/core/transport.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as model;
import 'package:livekit_client/src/support/websocket.dart';
import 'package:livekit_client/src/types/internal.dart';
import 'package:voicechat_probe/route_coordinator.dart';
import 'package:voicechat_probe/route_transport.dart';
import 'package:voicechat_probe/routed_livekit_engine.dart';
import 'media_routes_test.dart' show RestartPeer;
import 'route_coordinator_test.dart' show config, health;

class RecordingSignal extends SignalClient {
  final Object failure;
  RecordingSignal({Object? failure})
    : failure = failure ?? StateError('signaling boundary'),
      super(LiveKitWebSocket.connect);
  String? destination;
  String? authorization;
  lk.ConnectOptions? options;
  lk.RoomOptions? room;
  bool? resumed;

  @override
  Future<void> connect(
    String uriString,
    String token, {
    required lk.ConnectOptions connectOptions,
    required lk.RoomOptions roomOptions,
    bool reconnect = false,
    model.ReconnectReason? reconnectReason,
  }) async {
    destination = uriString;
    authorization = token;
    options = connectOptions;
    room = roomOptions;
    resumed = reconnect;
    throw failure;
  }
}

class RecordingTransport implements Transport {
  @override
  final RestartPeer pc = RestartPeer();
  bool disposed = false;
  @override
  Future<bool> dispose() async {
    disposed = true;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'initial connect reports network failure without retrying auth, rate limit or pin errors',
    () async {
      final cases = <(Object, bool)>[
        (const WebSocketException('synthetic network error'), true),
        (TimeoutException('synthetic timeout'), true),
        (
          lk.ConnectException(
            'upstream unavailable',
            reason: lk.ConnectionErrorReason.NotAllowed,
            statusCode: 503,
          ),
          true,
        ),
        for (final code in [401, 403, 429])
          (
            lk.ConnectException(
              'request denied',
              reason: lk.ConnectionErrorReason.NotAllowed,
              statusCode: code,
            ),
            false,
          ),
        (
          lk.CertificatePinningException('pin mismatch', host: 'b.example.com'),
          false,
        ),
      ];
      for (final (failure, retryable) in cases) {
        expect(mediaNetworkFailure(failure), retryable);
        var bothReady = false;
        final coordinator = RouteCoordinator(
          config(),
          clientFactory: () => MockClient(
            (r) async => health(
              r,
              matrix: bothReady || r.url.host.startsWith('b.'),
              control: bothReady || r.url.host.startsWith('b.'),
            ),
          ),
        );
        addTearDown(coordinator.close);
        await coordinator.refresh();
        final network = RouteTransport(
          origin: coordinator.config.canonicalOrigin,
          routes: coordinator.config.edges.map((e) => e.origin).toList(),
          inner: MockClient((r) async => health(r)),
          coordinator: coordinator,
        );
        addTearDown(network.close);
        final signal = RecordingSignal(failure: failure);
        addTearDown(signal.dispose);
        final engine = RoutedLiveKitEngine(
          network: network,
          canonicalUrl: 'wss://chat.example.com/livekit',
          canRecover: () => true,
          roomOptions: const lk.RoomOptions(),
          signalClient: signal,
          loadOptions: () async => throw StateError(
            'Initial failure must not replay or refresh media by itself',
          ),
        );
        addTearDown(engine.dispose);
        final destination = network.websocketUrl(
          'wss://chat.example.com/livekit',
        );
        bothReady = true;
        await expectLater(
          engine.connect(destination, 'existing-token'),
          throwsA(same(failure)),
        );
        expect(
          coordinator.route(RouteService.signaling)!.id,
          retryable ? 'c' : 'b',
        );
        expect(coordinator.route(RouteService.control)!.id, 'b');
        expect(signal.destination, destination);
      }
    },
  );
  for (final fullRestart in [false, true]) {
    test(
      '${fullRestart ? "restart" : "resume"} awaits fresh TURN and changes only transport state',
      () async {
        var bothReady = false;
        final coordinator = RouteCoordinator(
          config(),
          clientFactory: () => MockClient(
            (r) async => health(
              r,
              matrix: bothReady ? true : r.url.host.startsWith('b.'),
              control: bothReady ? true : r.url.host.startsWith('b.'),
            ),
          ),
        );
        addTearDown(coordinator.close);
        await coordinator.refresh();
        final network = RouteTransport(
          origin: coordinator.config.canonicalOrigin,
          routes: coordinator.config.edges.map((e) => e.origin).toList(),
          inner: MockClient((r) async => health(r)),
          coordinator: coordinator,
        );
        addTearDown(network.close);
        final signal = RecordingSignal();
        addTearDown(signal.dispose);
        final requested = Completer<void>();
        final credentials = Completer<lk.ConnectOptions>();
        const roomOptions = lk.RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        );
        final engine = RoutedLiveKitEngine(
          canRecover: () => true,
          network: network,
          canonicalUrl: 'wss://chat.example.com/livekit',
          signalClient: signal,
          roomOptions: roomOptions,
          loadOptions: () {
            requested.complete();
            return credentials.future;
          },
        );
        addTearDown(engine.dispose);
        await expectLater(
          engine.restartConnection(regionUrl: 'wss://untrusted.example.com'),
          throwsStateError,
        );
        expect(requested.isCompleted, isFalse);
        final oldOptions = lk.ConnectOptions(
          autoSubscribe: false,
          rtcConfiguration: const lk.RTCConfiguration(
            encodedInsertableStreams: true,
            iceTransportPolicy: lk.RTCIceTransportPolicy.relay,
          ),
        );
        engine.connectOptions = oldOptions;
        engine.url = network.websocketUrl('wss://chat.example.com/livekit');
        engine.token = 'existing-lease-token';
        final peers = [RecordingTransport(), RecordingTransport()];
        for (final peer in peers) {
          peer.pc.configuration.addAll({
            'encodedInsertableStreams': true,
            'iceTransportPolicy': 'relay',
          });
        }
        engine.publisher = peers[0];
        engine.subscriber = peers[1];
        bothReady = true;
        final pending = expectLater(
          fullRestart
              ? engine.restartConnection()
              : engine.resumeConnection(ClientDisconnectReason.signal),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'signaling boundary',
            ),
          ),
        );
        await requested.future;
        expect(signal.destination, isNull);
        expect(peers.every((p) => p.pc.steps.isEmpty && !p.disposed), isTrue);
        const servers = [
          lk.RTCIceServer(
            urls: ['turn:turn-c.example.com:3478'],
            username: 'fresh-user',
            credential: 'fresh-secret',
          ),
        ];
        credentials.complete(
          const lk.ConnectOptions(
            rtcConfiguration: lk.RTCConfiguration(iceServers: servers),
          ),
        );
        await pending;
        expect(signal.destination, 'wss://c.example.com:443/livekit');
        expect(signal.authorization, 'existing-lease-token');
        expect(identical(signal.room, roomOptions), isTrue);
        expect(signal.resumed, !fullRestart);
        expect(signal.options!.autoSubscribe, isFalse);
        expect(
          identical(signal.options!.timeouts, oldOptions.timeouts),
          isTrue,
        );
        expect(
          signal.options!.rtcConfiguration.encodedInsertableStreams,
          isTrue,
        );
        expect(
          signal.options!.rtcConfiguration.iceTransportPolicy,
          lk.RTCIceTransportPolicy.relay,
        );
        expect(signal.options!.rtcConfiguration.iceServers, servers);
        for (final peer in peers) {
          expect(peer.disposed, fullRestart);
          expect(peer.pc.steps, fullRestart ? isEmpty : ['configure']);
          expect(peer.pc.configuration['encodedInsertableStreams'], isTrue);
          expect(peer.pc.configuration['iceTransportPolicy'], 'relay');
          if (!fullRestart) {
            expect(
              peer.pc.configuration['iceServers'],
              servers.map((s) => s.toMap()).toList(),
            );
          }
        }
      },
    );
  }

  for (final mode in ['empty', 'dispose', 'revoked']) {
    test('$mode during TURN refresh prevents signaling', () async {
      final closeDuringRefresh = mode == 'dispose';
      var authorized = true;
      final coordinator = RouteCoordinator(
        config(),
        clientFactory: () => MockClient((r) async => health(r)),
      );
      addTearDown(coordinator.close);
      final network = RouteTransport(
        origin: coordinator.config.canonicalOrigin,
        routes: coordinator.config.edges.map((e) => e.origin).toList(),
        inner: MockClient((r) async => health(r)),
        coordinator: coordinator,
      );
      addTearDown(network.close);
      final signal = RecordingSignal();
      addTearDown(signal.dispose);
      final requested = Completer<void>();
      final credentials = Completer<lk.ConnectOptions>();
      final engine = RoutedLiveKitEngine(
        canRecover: () => authorized,
        network: network,
        canonicalUrl: 'wss://chat.example.com/livekit',
        signalClient: signal,
        roomOptions: const lk.RoomOptions(),
        loadOptions: () {
          requested.complete();
          return credentials.future;
        },
      );
      if (!closeDuringRefresh) addTearDown(engine.dispose);
      final pending = engine.resumeConnection(ClientDisconnectReason.signal);
      final check = expectLater(
        pending,
        mode != 'empty' ? completes : throwsFormatException,
      );
      await requested.future;
      if (closeDuringRefresh) await engine.dispose();
      if (mode == 'revoked') authorized = false;
      credentials.complete(const lk.ConnectOptions());
      await check;
      expect(signal.destination, isNull);
      expect(engine.url, isNull);
    });
  }
}
