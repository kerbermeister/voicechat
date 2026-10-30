import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vodozemac/vodozemac.dart' as vod;
import 'route_config.dart';
import 'transport.dart';
import 'catalog_http_native.dart'
    if (dart.library.js_interop) 'catalog_http_web.dart';

const routeCatalogDomain = 'voicechat-route-catalog-v1\n';

class VerifiedRouteCatalog {
  final int revision, expiresAt;
  final String payload, envelope;
  final RouteConfig config;
  const VerifiedRouteCatalog(
    this.revision,
    this.expiresAt,
    this.payload,
    this.envelope,
    this.config,
  );
}

/// Call only after the application's vodozemac initialization. The signing key is
/// an installation key, never a user's Matrix identity or a key learned online.
VerifiedRouteCatalog verifyRouteCatalog(
  String envelope,
  String publicKey,
  RouteConfig bootstrap, {
  VerifiedRouteCatalog? previous,
  bool restoring = false,
  DateTime? now,
}) {
  if (utf8.encode(envelope).length > 65536 ||
      base64Decode(publicKey).length != 32) {
    throw const FormatException('Invalid catalog size or key');
  }
  final raw = jsonDecode(envelope);
  if (raw is! Map<String, dynamic> ||
      raw.length != 2 ||
      raw['payload'] is! String ||
      raw['signature'] is! String) {
    throw const FormatException('Invalid catalog envelope');
  }
  final bytes = base64Decode(raw['payload']);
  final signature = base64Decode(raw['signature']);
  if (bytes.length > 48000 || signature.length != 64) {
    throw const FormatException('Invalid catalog payload');
  }
  final payload = utf8.decode(bytes);
  vod.Ed25519PublicKey.fromBytes(base64Decode(publicKey)).verify(
    message: routeCatalogDomain + payload,
    signature: vod.Ed25519Signature.fromBytes(signature),
  );
  final value = jsonDecode(payload);
  const fields = {'schema', 'revision', 'issued_at', 'expires_at', 'topology'};
  if (value is! Map<String, dynamic> ||
      value.length != fields.length ||
      !value.keys.every(fields.contains) ||
      value['schema'] is! int ||
      value['schema'] != 1 ||
      value['revision'] is! int ||
      value['revision'] < 1 ||
      value['revision'] > 9007199254740991 ||
      value['issued_at'] is! int ||
      value['expires_at'] is! int) {
    throw const FormatException('Invalid catalog version');
  }
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final issued = value['issued_at'] as int,
      expires = value['expires_at'] as int;
  if (issued < 0 ||
      expires <= issued ||
      expires - issued > 30 * 86400 ||
      issued > seconds + 300 ||
      (!restoring && expires <= seconds)) {
    throw const FormatException('Catalog outside its validity interval');
  }
  final config = RouteConfig.parse(jsonEncode(value['topology']));
  if (config.serviceId != bootstrap.serviceId ||
      config.matrixServerName != bootstrap.matrixServerName ||
      config.canonicalOrigin != bootstrap.canonicalOrigin) {
    throw const FormatException('Catalog cannot change installation identity');
  }
  final revision = value['revision'] as int;
  if (previous != null &&
      (revision < previous.revision ||
          (revision == previous.revision && payload != previous.payload))) {
    throw const FormatException('Catalog rollback or conflicting revision');
  }
  return VerifiedRouteCatalog(revision, expires, payload, envelope, config);
}

/// Retains one signed blob: a crash cannot split the revision from its routes.
/// An expired cached blob may retain known routes, but cannot admit new ones.
class RouteCatalog {
  final RouteConfig bootstrap;
  final String publicKey;
  final SharedPreferences _preferences;
  final Uri? discoveryOrigin;
  VerifiedRouteCatalog? current;
  Future<RouteConfig>? _pending;
  final _clients = <http.Client>{};
  bool _closed = false;
  String get _cacheKey => 'route-catalog:${bootstrap.serviceId}:$publicKey';
  RouteConfig get config => current?.config ?? bootstrap;

  RouteCatalog(
    this.bootstrap,
    this.publicKey,
    this._preferences, {
    this.discoveryOrigin,
  }) {
    if (base64Decode(publicKey).length != 32) {
      throw const FormatException('Invalid route catalog public key');
    }
    if (discoveryOrigin != null &&
        secureEndpoint(discoveryOrigin.toString()).toString() !=
            discoveryOrigin!.origin) {
      throw const FormatException(
        'Catalog discovery requires a canonical secure origin',
      );
    }
    final cached = _preferences.getString(_cacheKey);
    if (cached != null) {
      // A corrupt local high-water mark is explicit; do not reset it and accept
      // an older remote list silently. Account/vault data remains untouched.
      current = verifyRouteCatalog(
        cached,
        publicKey,
        bootstrap,
        restoring: true,
      );
    }
  }

  Future<RouteConfig> refresh() {
    if (_closed) return Future.value(config);
    return _pending ??= _refresh().whenComplete(() => _pending = null);
  }

  Future<RouteConfig> _refresh() async {
    // The current website is a discovery hint, never an authorized API route.
    // Every response still needs the pinned signature; redirects stay disabled.
    // A reachable website/bootstrap must still recover discovery when every
    // API entry in the cached catalog has been replaced or become unreachable.
    final origins = {
      if (discoveryOrigin != null) discoveryOrigin!,
      ...bootstrap.webOrigins,
      ...bootstrap.edges.map((edge) => edge.origin),
      ...config.webOrigins,
      ...config.edges.map((edge) => edge.origin),
    };
    final candidates = await Future.wait(
      origins.map((origin) async {
        final client = catalogClient();
        _clients.add(client);
        final abort = Completer<void>();
        try {
          return await (() async {
            final request = http.AbortableRequest(
              'GET',
              origin.resolve('/.well-known/voicechat/routes.json'),
              abortTrigger: abort.future,
            )..followRedirects = false;
            final response = await client.send(request);
            if (response.statusCode != 200 ||
                response.headers['content-type']?.split(';').first !=
                    'application/json') {
              return null;
            }
            final bytes = <int>[];
            await for (final chunk in response.stream) {
              if (bytes.length + chunk.length > 65536) return null;
              bytes.addAll(chunk);
            }
            return verifyRouteCatalog(
              utf8.decode(bytes),
              publicKey,
              bootstrap,
              previous: current,
            );
          })().timeout(const Duration(milliseconds: 1500));
        } catch (_) {
          return null;
        } finally {
          abort.complete();
          _clients.remove(client);
          client.close();
        }
      }),
    );
    if (_closed) return config;
    final valid = candidates.whereType<VerifiedRouteCatalog>().toList()
      ..sort((a, b) => b.revision.compareTo(a.revision));
    if (valid.isEmpty) return config;
    final newest = valid.first;
    if (valid.any(
      (v) => v.revision == newest.revision && v.payload != newest.payload,
    )) {
      throw const FormatException('Conflicting signed catalogs');
    }
    if (newest.revision == current?.revision) return config;
    if (!await _preferences.setString(_cacheKey, newest.envelope)) {
      throw StateError('Could not persist route catalog');
    }
    if (!_closed) current = newest;
    return config;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
  }
}
