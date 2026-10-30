import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'route_config.dart';
import 'route_catalog.dart';

enum RouteService { matrix, control, signaling }

enum RouteState { checking, connected, recovering, unavailable, closed }

class RouteSample {
  final RouteEdge edge;
  final Duration latency;
  final bool matrix, control;
  const RouteSample(this.edge, this.latency, this.matrix, this.control);
  bool ready(RouteService service) =>
      service == RouteService.matrix ? matrix : control;
}

/// Rank availability before latency. A healthy previous route needs both speed
/// thresholds to be displaced, avoiding oscillation on noisy measurements.
RouteEdge? chooseRoute(
  List<RouteSample> samples,
  RouteService service, {
  RouteEdge? previous,
  bool reconsiderHealthy = true,
}) {
  final byEdge = <RouteEdge, List<int>>{};
  for (final sample in samples) {
    if (sample.ready(service)) {
      byEdge
          .putIfAbsent(sample.edge, () => [])
          .add(sample.latency.inMicroseconds);
    }
  }
  if (byEdge.isEmpty) return null;
  double median(RouteEdge edge) {
    final times = byEdge[edge]!..sort();
    final middle = times.length ~/ 2;
    return times.length.isOdd
        ? times[middle].toDouble()
        : (times[middle - 1] + times[middle]) / 2;
  }

  final ranked = byEdge.keys.toList()
    ..sort((a, b) {
      final count = byEdge[b]!.length.compareTo(byEdge[a]!.length);
      if (count != 0) return count;
      final speed = median(a).compareTo(median(b));
      if (speed != 0) return speed;
      if (a == previous) return -1;
      if (b == previous) return 1;
      return a.id.compareTo(b.id);
    });
  final best = ranked.first;
  if (previous == null || !byEdge.containsKey(previous)) return best;
  if (!reconsiderHealthy) return previous;
  if (byEdge[previous]!.length == byEdge[best]!.length) {
    final improvement = median(previous) - median(best);
    if (improvement < 50000 || improvement < median(previous) * .2) {
      return previous;
    }
  }
  return best;
}

/// One coordinator per logical session; probes never receive user credentials.
/// Request replay belongs to the caller that knows the operation's semantics.
class RouteCoordinator {
  RouteConfig _config;
  RouteConfig get config => _config;
  final RouteCatalog? catalog;
  final http.Client Function() _clientFactory;
  final _changes = StreamController<RouteState>.broadcast();
  final _clients = <http.Client>{};
  final _selected = <RouteService, RouteEdge?>{};
  final _failedUntil = <(RouteService, Uri), DateTime>{};
  Future<void>? _pending;
  Timer? _monitor;
  Timer? _catalogTimer;
  bool _monitoring = false;
  int _failures = 0;
  bool _closed = false;
  final _selectionClock = Stopwatch()..start();
  Stopwatch? _recoveryClock;
  Duration? _selectionTime, _recoveryTime;
  RouteService? _lastFailedService;
  int _recoveryAttempts = 0;

  Map<String, Object?> diagnostics() => {
    'state': state.name,
    'routes': {
      for (final service in RouteService.values)
        service.name: route(service)?.id,
    },
    'initial_selection_ms': _selectionTime?.inMilliseconds,
    'last_recovery_ms': _recoveryTime?.inMilliseconds,
    'recovery_attempts': _recoveryAttempts,
    'last_failed_service': _lastFailedService?.name,
  };

  RouteState state = RouteState.checking;
  Stream<RouteState> get changes => _changes.stream;

  RouteCoordinator(
    RouteConfig config, {
    http.Client Function()? clientFactory,
    this.catalog,
  }) : _config = config,
       _clientFactory = clientFactory ?? http.Client.new;

  RouteEdge? route(RouteService service) => _selected[service];

  Future<void> start() async {
    _monitoring = true;
    await refresh(reconsiderHealthy: true);
    if (!_closed && catalog != null) {
      unawaited(_updateCatalog());
      _catalogTimer ??= Timer.periodic(
        const Duration(minutes: 15),
        (_) => _updateCatalog(),
      );
    }
  }

  Future<void> _updateCatalog() async {
    try {
      final next = await catalog!.refresh();
      await _pending;
      if (_closed || identical(next, _config)) return;
      _config = next;
      for (final service in RouteService.values) {
        final previous = _selected[service];
        _selected[service] = next.edges
            .where((e) => e.id == previous?.id && e.origin == previous?.origin)
            .firstOrNull;
      }
      await refresh();
    } catch (_) {
      // Keep the last verified routes; a catalog failure is not an account error.
    }
  }

  Future<void> refresh({bool reconsiderHealthy = false}) {
    if (_closed) return Future.value();
    if (_pending != null) return _pending!;
    _monitor?.cancel();
    return _pending = _refresh(reconsiderHealthy).whenComplete(() {
      _pending = null;
      if (!_closed && _monitoring) {
        final allReady = RouteService.values.every((s) => _selected[s] != null);
        _failures = allReady ? 0 : min(_failures + 1, 6);
        final delayMs = allReady
            ? 10000
            : min(
                30000,
                ((1 << (_failures - 1)) *
                        1000 *
                        (.8 + Random().nextDouble() * .4))
                    .round(),
              );
        _monitor = Timer(Duration(milliseconds: delayMs), refresh);
      }
    });
  }

  Future<void> recover() {
    if (_closed) return Future.value();
    _recoveryClock ??= Stopwatch()..start();
    _recoveryAttempts++;
    _setState(RouteState.recovering);
    return refresh();
  }

  /// A healthy readiness response cannot disprove a failed client request or
  /// WebSocket. Prefer another ready path briefly, without poisoning other APIs.
  Future<void> reportFailure(RouteService service, Uri origin) {
    if (_closed) return Future.value();
    if (config.edges.any((edge) => edge.origin == origin)) {
      _lastFailedService = service;
      _failedUntil.remove((service, origin));
      _failedUntil[(service, origin)] = DateTime.now().add(
        const Duration(seconds: 10),
      );
    }
    return recover();
  }

  Future<void> _refresh(bool reconsiderHealthy) async {
    if (_selected.values.every((value) => value == null)) {
      _setState(RouteState.checking);
    }
    final observations = await Future.wait(
      config.edges.map((edge) async {
        final samples = <RouteSample>[];
        for (var i = 0; i < 2 && !_closed; i++) {
          final sample = await _probe(edge);
          if (sample != null) samples.add(sample);
        }
        return samples;
      }),
    );
    if (_closed) return;
    final samples = observations.expand((s) => s).toList();
    final previous = {
      for (final service in RouteService.values)
        service: _selected[service]?.origin,
    };
    final now = DateTime.now();
    _failedUntil.removeWhere(
      (key, until) =>
          !until.isAfter(now) ||
          !config.edges.any((edge) => edge.origin == key.$2),
    );
    for (final service in RouteService.values) {
      var alternatives = samples
          .where(
            (sample) =>
                !_failedUntil.containsKey((service, sample.edge.origin)),
          )
          .toList();
      if (!alternatives.any((sample) => sample.ready(service))) {
        // If every ready entry failed recently, retry the least recent failure,
        // not the same broken socket forever. Map insertion order is failure order.
        final oldest = _failedUntil.keys
            .where(
              (key) =>
                  key.$1 == service &&
                  samples.any(
                    (sample) =>
                        sample.ready(service) && sample.edge.origin == key.$2,
                  ),
            )
            .firstOrNull;
        alternatives = oldest == null
            ? samples
            : samples
                  .where((sample) => sample.edge.origin == oldest.$2)
                  .toList();
      }
      _selected[service] = chooseRoute(
        // A sole ready entry is still worth retrying. Cooldowns must not turn
        // a one-VPS transient failure into an artificial ten-second outage.
        alternatives,
        service,
        previous: _selected[service],
        reconsiderHealthy: reconsiderHealthy,
      );
    }
    if (RouteService.values.every((service) => _selected[service] != null)) {
      _selectionTime ??= _selectionClock.elapsed;
      if (_recoveryClock != null) {
        _recoveryTime = _recoveryClock!.elapsed;
        _recoveryClock = null;
      }
    }
    _setState(
      _selected.values.any((route) => route != null)
          ? RouteState.connected
          : RouteState.unavailable,
    );
    if (RouteService.values.any(
      (service) => previous[service] != _selected[service]?.origin,
    )) {
      _changes.add(state);
    }
  }

  Future<RouteSample?> _probe(RouteEdge edge) async {
    final client = _clientFactory();
    _clients.add(client);
    final abort = Completer<void>();
    final clock = Stopwatch()..start();
    try {
      return await (() async {
        final request =
            http.AbortableRequest(
                'GET',
                edge.origin.resolve('/health/route'),
                abortTrigger: abort.future,
              )
              ..followRedirects = false
              ..maxRedirects = 0
              ..headers['Accept'] = 'application/json'
              ..headers['Cache-Control'] = 'no-cache';
        final response = await client.send(request);
        if (![200, 503].contains(response.statusCode) ||
            response.headers['content-type']?.split(';').first.trim() !=
                'application/json') {
          return null;
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 4096) return null;
          bytes.addAll(chunk);
        }
        final value = jsonDecode(utf8.decode(bytes));
        const fields = {
          'schema',
          'service_id',
          'edge_id',
          'age_ms',
          'matrix',
          'control',
        };
        if (value is! Map<String, dynamic> ||
            value.length != fields.length ||
            !value.keys.every(fields.contains) ||
            value['schema'] is! int ||
            value['schema'] != 1 ||
            value['service_id'] != config.serviceId ||
            value['edge_id'] != edge.id ||
            value['age_ms'] is! int ||
            value['age_ms'] < 0 ||
            value['age_ms'] > 2000 ||
            value['matrix'] is! bool ||
            value['control'] is! bool ||
            (response.statusCode == 200) !=
                (value['matrix'] && value['control'])) {
          return null;
        }
        return RouteSample(
          edge,
          clock.elapsed,
          value['matrix'],
          value['control'],
        );
      })().timeout(const Duration(milliseconds: 1500));
    } on Exception {
      return null;
    } finally {
      abort.complete();
      _clients.remove(client);
      client.close();
    }
  }

  void _setState(RouteState next) {
    if (_closed || state == next) return;
    state = next;
    _changes.add(next);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _monitor?.cancel();
    _catalogTimer?.cancel();
    catalog?.close();
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
    _selected.clear();
    state = RouteState.closed;
    _changes.close();
  }
}
