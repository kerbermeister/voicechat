import 'dart:convert';
import 'transport.dart';

class RouteEdge {
  final String id;
  final Uri origin;
  final String turnHost;
  const RouteEdge(this.id, this.origin, this.turnHost);
}

/// Validated names from the compiled bootstrap or a verified signed catalog.
class RouteConfig {
  final String serviceId, matrixServerName;
  final Uri canonicalOrigin;
  final List<Uri> webOrigins;
  final List<RouteEdge> edges;
  RouteConfig._(
    this.serviceId,
    this.matrixServerName,
    this.canonicalOrigin,
    this.webOrigins,
    this.edges,
  );

  factory RouteConfig.parse(String source) {
    final value = _fields(jsonDecode(source), {
      'schema',
      'service_id',
      'matrix_server_name',
      'canonical_origin',
      'web_origins',
      'edges',
    });
    if (value['schema'] is! int ||
        value['schema'] != 1 ||
        value['service_id'] is! String ||
        !RegExp(r'^[a-z][a-z0-9-]{0,62}$').hasMatch(value['service_id'])) {
      throw const FormatException('Invalid route schema or service ID');
    }
    final server = _hostname(value['matrix_server_name']);
    final canonical = _origin(value['canonical_origin']);
    final rawWeb = value['web_origins'];
    if (rawWeb is! List || rawWeb.isEmpty || rawWeb.length > 33) {
      throw const FormatException('Invalid web origins');
    }
    final web = rawWeb.map(_origin).toList();
    if (web.toSet().length != web.length || !web.contains(canonical)) {
      throw const FormatException('Invalid web origins');
    }
    final rawEdges = value['edges'];
    if (rawEdges is! List || (rawEdges.isEmpty || rawEdges.length > 32)) {
      throw const FormatException('Between 1 and 32 edges required');
    }
    final edges = rawEdges.map((raw) {
      final edge = _fields(raw, {'id', 'origin', 'turn_host'});
      if (edge['id'] is! String ||
          !RegExp(r'^[a-z][a-z0-9-]{0,31}$').hasMatch(edge['id'])) {
        throw const FormatException('Invalid edge ID');
      }
      final origin = _origin(edge['origin']);
      if (origin.scheme != canonical.scheme) {
        throw const FormatException('Mixed route schemes');
      }
      return RouteEdge(edge['id'], origin, _hostname(edge['turn_host']));
    }).toList();
    if (edges.map((e) => e.id).toSet().length != edges.length ||
        edges.map((e) => e.origin).toSet().length != edges.length ||
        edges.map((e) => e.turnHost).toSet().length != edges.length) {
      throw const FormatException('Duplicate edge');
    }
    return RouteConfig._(
      value['service_id'],
      server,
      canonical,
      List.unmodifiable(web),
      List.unmodifiable(edges),
    );
  }

  static Map<String, dynamic> _fields(dynamic value, Set<String> fields) {
    if (value is! Map<String, dynamic> ||
        value.length != fields.length ||
        !value.keys.every(fields.contains)) {
      throw const FormatException('Unexpected route fields');
    }
    return value;
  }

  static String _hostname(dynamic value) {
    if (value is! String ||
        value.length > 253 ||
        !RegExp(r'^[a-z0-9]+(?:[.-][a-z0-9]+)*$').hasMatch(value) ||
        value
            .split('.')
            .any(
              (s) => s.length > 63 || s.startsWith('-') || s.endsWith('-'),
            )) {
      throw const FormatException('Canonical ASCII hostname required');
    }
    return value;
  }

  static Uri _origin(dynamic value) {
    if (value is! String || RegExp(r'\s').hasMatch(value)) {
      throw const FormatException('Invalid origin');
    }
    final Uri uri;
    try {
      uri = secureEndpoint(value);
    } on ArgumentError {
      throw const FormatException('Invalid secure origin');
    }
    if (value != uri.origin || uri.port < 1 || uri.port > 65535) {
      throw const FormatException('Canonical origin required');
    }
    return uri;
  }
}
