// LiveKit 2.13.1 exposes Engine injection but not an awaited reconnect hook.
// Keep this adapter isolated; SDK upgrades must rerun resume/restart probes.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:livekit_client/src/core/engine.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as model;
import 'package:livekit_client/src/types/internal.dart';
import 'package:livekit_client/src/support/region_url_provider.dart';
import 'package:livekit_client/src/support/websocket.dart';
import 'route_transport.dart';
import 'media_statistics.dart';
import 'route_coordinator.dart';

bool mediaNetworkFailure(Object error) {
  if (error is lk.ConnectException) {
    return {502, 503, 504}.contains(error.statusCode) ||
        (error.statusCode == 0 &&
            error.reason != lk.ConnectionErrorReason.NotAllowed);
  }
  return error is WebSocketException ||
      error is http.ClientException ||
      error is TimeoutException ||
      error is lk.TimeoutException;
}

/// Refreshes transport destinations before SDK resume, keeping Room/key provider
/// and authorization lifecycle with the caller. A UI reconnect event is too late
/// to await this work reliably.
class RoutedLiveKitEngine extends Engine {
  final RouteTransport network;
  final String canonicalUrl;
  final Future<lk.ConnectOptions> Function() loadOptions;
  final bool Function() canRecover;

  RoutedLiveKitEngine({
    required this.network,
    required this.canonicalUrl,
    required this.loadOptions,
    required this.canRecover,
    required super.roomOptions,
    super.signalClient,
  }) : super(connectOptions: const lk.ConnectOptions(autoSubscribe: false));

  Future<void> _reportFailure(String failedUrl) {
    final failed = Uri.parse(failedUrl);
    return network.coordinator!
        .reportFailure(
          RouteService.signaling,
          Uri.parse(
            failed
                .replace(scheme: failed.scheme == 'wss' ? 'https' : 'http')
                .origin,
          ),
        )
        .timeout(const Duration(seconds: 4));
  }

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
    RegionUrlProvider? regionUrlProvider,
  }) async {
    if (regionUrlProvider != null) {
      throw StateError('External media region is not a trusted route');
    }
    try {
      await super.connect(
        url,
        token,
        connectOptions: connectOptions,
        roomOptions: roomOptions,
        fastConnectOptions: fastConnectOptions,
      );
    } catch (error) {
      if (!isClosed && canRecover() && mediaNetworkFailure(error)) {
        try {
          await _reportFailure(url);
        } catch (_) {
          // Preserve the original connection error for the caller's retry/lease
          // policy. A readiness failure must not replace an authorization error.
        }
      }
      rethrow;
    }
  }

  Future<bool> _prepare({required bool updatePeers}) async {
    if (isClosed || !canRecover()) return false;
    final coordinator = network.coordinator!;
    await (url == null ||
            signalClient.connectionState == lk.ConnectionState.connected
        ? coordinator.recover().timeout(const Duration(seconds: 4))
        : _reportFailure(url!));
    final config = coordinator.config;
    final fresh = await loadOptions().timeout(const Duration(seconds: 5));
    if (isClosed || !canRecover()) return false;
    if (!identical(config, coordinator.config)) {
      throw StateError('Route catalog changed during media recovery');
    }
    final servers = fresh.rtcConfiguration.iceServers;
    if (servers == null || servers.isEmpty) {
      throw const FormatException('Trusted TURN configuration required');
    }
    if (updatePeers) {
      for (final transport in [publisher, subscriber]) {
        if (transport == null) continue;
        if (isClosed ||
            !canRecover() ||
            (transport != publisher && transport != subscriber)) {
          return false;
        }
        await transport.pc.setConfiguration({
          ...transport.pc.getConfiguration,
          'iceServers': servers.map((server) => server.toMap()).toList(),
        });
      }
    }
    if (isClosed || !canRecover()) return false;
    if (!identical(config, coordinator.config)) {
      throw StateError('Route catalog changed during media recovery');
    }
    url = network.websocketUrl(canonicalUrl);
    final previous = connectOptions;
    connectOptions = lk.ConnectOptions(
      autoSubscribe: previous.autoSubscribe,
      protocolVersion: previous.protocolVersion,
      clientProtocolVersion: previous.clientProtocolVersion,
      timeouts: previous.timeouts,
      rtcConfiguration: previous.rtcConfiguration.copyWith(iceServers: servers),
    );
    return true;
  }

  @override
  Future<void> resumeConnection(
    ClientDisconnectReason reason, {
    model.ReconnectReason? reconnectReason,
  }) async {
    if (!await _prepare(updatePeers: true)) return;
    await super.resumeConnection(reason, reconnectReason: reconnectReason);
  }

  @override
  Future<void> restartConnection({String? regionUrl}) async {
    // Self-hosted failover may only use the verified catalog, never a cloud
    // region hint learned through the SDK's separate discovery mechanism.
    if (regionUrl != null) {
      throw StateError('External media region is not a trusted route');
    }
    if (!await _prepare(updatePeers: false)) return;
    await super.restartConnection();
  }
}

final _statisticsPeerIds = Expando<int>();
int _nextStatisticsPeerId = 0;

/// Query each transport once, rather than once per publication in a large group.
Future<List<rtc.StatsReport>> mediaRoomReports(lk.Room room) async {
  final publisher = room.engine.publisher?.pc;
  final subscriber = room.engine.subscriber?.pc;
  final peers = {
    if (publisher != null) publisher,
    if (subscriber != null) subscriber,
  };
  final snapshots = await Future.wait(
    peers.map((peer) async {
      final index = _statisticsPeerIds[peer] ??= _nextStatisticsPeerId++;
      final reports = await peer.getStats().timeout(const Duration(seconds: 2));
      Map<String, dynamic> scopedValues(rtc.StatsReport report) => {
        ...report.values,
        for (final field in const [
          'selectedCandidatePairId',
          'localCandidateId',
          'remoteCandidateId',
          'transportId',
          'codecId',
          'localId',
          'remoteId',
        ])
          if (report.values[field] is String)
            field: '$index/${report.values[field]}',
      };
      return [
        for (final report in reports)
          rtc.StatsReport(
            '$index/${report.id}',
            report.type,
            report.timestamp,
            scopedValues(report),
          ),
      ];
    }),
  );
  if (publisher != room.engine.publisher?.pc ||
      subscriber != room.engine.subscriber?.pc) {
    return [];
  }
  return snapshots.expand((reports) => reports).toList();
}

/// A room owns one sampler, independent of admission and renderer visibility.
class RoomMediaStatistics {
  final _statistics = MediaStatistics();
  final _clock = Stopwatch()..start();
  final _history = <Map<String, Object>>[];
  lk.Room? _room;
  Timer? _timer;
  bool _sampling = false;
  List<Map<String, Object>> get history => List.unmodifiable(_history);

  void start(lk.Room room) {
    stop();
    _room = room;
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(sample()),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _room = null;
    _statistics.reset();
  }

  Future<void> sample() async {
    final room = _room;
    if (room == null || _sampling) return;
    _sampling = true;
    try {
      final reports = await mediaRoomReports(room);
      if (!identical(room, _room)) return;
      _record({'streams': _statistics.read(reports)});
    } catch (_) {
      if (identical(room, _room)) {
        _statistics.reset();
        _record({'statistics': 'unavailable'});
      }
    } finally {
      _sampling = false;
    }
  }

  void _record(Map<String, Object> values) {
    _history.add(
      Map.unmodifiable({'elapsed_ms': _clock.elapsedMilliseconds, ...values}),
    );
    if (_history.length > 60) _history.removeAt(0);
  }
}
