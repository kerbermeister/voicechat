import 'dart:async';
import 'package:http/http.dart' as http;
import 'route_coordinator.dart';
import 'transport.dart';

/// Changes the network destination without changing Matrix's homeserver identity.
/// Selection belongs to the connection coordinator; this transport never retries
/// a consumed request or guesses whether a mutation reached the server.
class RouteTransport extends http.BaseClient {
  final Uri origin;
  final List<Uri> routes;
  final http.Client _inner;
  final RouteCoordinator? coordinator;
  late Uri _selected;
  bool _closed = false;
  StreamSubscription<RouteState>? _routeChanges;
  final _syncRequests = <Completer<void>, Uri>{};

  RouteTransport({
    required Uri origin,
    required List<Uri> routes,
    required http.Client inner,
    this.coordinator,
  }) : origin = _origin(origin),
       routes = List.unmodifiable(routes.map(_origin)),
       _inner = inner {
    if (this.routes.isEmpty ||
        this.routes.toSet().length != this.routes.length ||
        this.routes.any((route) => route.scheme != this.origin.scheme)) {
      throw ArgumentError(
        'Distinct routes with the same secure scheme required',
      );
    }
    _selected = this.routes.first;
    if (coordinator != null &&
        (coordinator!.config.canonicalOrigin != this.origin ||
            coordinator!.config.edges.any(
              (e) => !this.routes.contains(e.origin),
            ))) {
      throw ArgumentError('Coordinator must belong to the same installation');
    }
    _routeChanges = coordinator?.changes.listen((_) {
      final next = coordinator!.route(RouteService.matrix)?.origin;
      for (final request in _syncRequests.entries.toList()) {
        if (request.value != next && !request.key.isCompleted) {
          request.key.complete();
        }
      }
    });
  }

  static Uri _origin(Uri value) {
    secureEndpoint(value.toString());
    if (value.hasQuery ||
        value.hasFragment ||
        (value.path.isNotEmpty && value.path != '/') ||
        value.port < 1 ||
        value.port > 65535) {
      throw ArgumentError('A bare HTTP(S) origin is required');
    }
    return Uri.parse(value.origin);
  }

  Uri get selected => _selected;

  /// A separate socket pool for control requests, sharing session routing only.
  RouteTransport fork() {
    final result = RouteTransport(
      origin: origin,
      routes: coordinator?.config.edges.map((e) => e.origin).toList() ?? routes,
      inner: http.Client(),
      coordinator: coordinator,
    );
    if (coordinator == null) result.select(_selected);
    return result;
  }

  String websocketUrl(String value) {
    final uri = secureEndpoint(value, websocket: true);
    final canonical = uri.replace(
      scheme: uri.scheme == 'wss' ? 'https' : 'http',
    );
    if (canonical.origin != origin.origin) {
      throw ArgumentError('Signaling is outside the configured installation');
    }
    final edge = coordinator?.route(RouteService.signaling)?.origin;
    if (coordinator != null && edge == null) {
      throw http.ClientException('No signaling route available');
    }
    final destination = edge ?? _selected;
    return uri
        .replace(host: destination.host, port: destination.port)
        .toString();
  }

  void select(Uri route) {
    if (_closed) throw StateError('Transport is closed');
    final candidate = _origin(route);
    if (!routes.contains(candidate)) {
      throw ArgumentError('Route is not in the trusted configuration');
    }
    _selected = candidate;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('Transport is closed');
    if (request.url.userInfo.isNotEmpty ||
        request.url.hasFragment ||
        request.url.origin != origin.origin) {
      throw http.ClientException('Request is outside the configured service');
    }
    // Capture once: a selection change must not redirect an in-flight body.
    final control =
        request.url.path == '/api' || request.url.path.startsWith('/api/');
    final service = control ? RouteService.control : RouteService.matrix;
    final route = coordinator == null
        ? _selected
        : coordinator!.route(service)?.origin;
    if (route == null) {
      unawaited(coordinator!.recover());
      throw http.ClientException('No route available');
    }
    final destination = request.url.replace(
      scheme: route.scheme,
      host: route.host,
      port: route.port,
    );
    final http.StreamedResponse response;
    final syncAbort =
        coordinator != null &&
            request.method == 'GET' &&
            request.url.path.startsWith('/_matrix/client/') &&
            request.url.path.endsWith('/sync')
        ? Completer<void>()
        : null;
    if (syncAbort != null) _syncRequests[syncAbort] = route;
    try {
      response = await _inner.send(
        _RoutedRequest(request, destination, syncAbort?.future),
      );
    } on http.RequestAbortedException {
      _syncRequests.remove(syncAbort);
      rethrow;
    } on http.ClientException {
      _syncRequests.remove(syncAbort);
      unawaited(coordinator?.reportFailure(service, route));
      rethrow;
    } on TimeoutException {
      _syncRequests.remove(syncAbort);
      unawaited(coordinator?.reportFailure(service, route));
      rethrow;
    } catch (_) {
      _syncRequests.remove(syncAbort);
      rethrow;
    }
    if ({502, 503, 504}.contains(response.statusCode)) {
      unawaited(coordinator?.reportFailure(service, route));
    }
    return http.StreamedResponse(
      _responseStream(response.stream, syncAbort, service, route),
      response.statusCode,
      contentLength: response.contentLength,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }

  Stream<List<int>> _responseStream(
    Stream<List<int>> source,
    Completer<void>? syncAbort,
    RouteService service,
    Uri route,
  ) async* {
    try {
      yield* source;
    } catch (error) {
      if (error is! http.RequestAbortedException) {
        unawaited(coordinator?.reportFailure(service, route));
      }
      rethrow;
    } finally {
      _syncRequests.remove(syncAbort);
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    unawaited(_routeChanges?.cancel());
    for (final request in _syncRequests.keys) {
      if (!request.isCompleted) request.complete();
    }
    _syncRequests.clear();
    _inner.close();
  }
}

class _RoutedRequest extends http.BaseRequest with http.Abortable {
  final http.ByteStream _body;
  @override
  final Future<void>? abortTrigger;

  _RoutedRequest(
    http.BaseRequest source,
    Uri destination, [
    Future<void>? routeAbort,
  ]) : _body = source.finalize(),
       abortTrigger = routeAbort == null
           ? (source is http.Abortable ? source.abortTrigger : null)
           : source is http.Abortable && source.abortTrigger != null
           ? Future.any([routeAbort, source.abortTrigger!])
           : routeAbort,
       super(source.method, destination) {
    // Multipart headers and content length are complete only after finalize().
    headers.addAll(source.headers);
    headers.remove('host');
    contentLength = source.contentLength;
    persistentConnection = source.persistentConnection;
    // A redirect is not a trusted route update, even if it stays on this origin.
    followRedirects = false;
    maxRedirects = 0;
  }

  @override
  http.ByteStream finalize() {
    super.finalize();
    return _body;
  }
}
