import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'transport.dart';

class LiveStreamError implements Exception {
  final int status;
  final String code;
  const LiveStreamError(this.status, this.code);
}

/// Owns its transport pool. Tokens and stream content never enter URLs or logs.
class LiveStreamApi {
  final Uri endpoint;
  final String Function() token;
  final http.Client client;
  LiveStreamApi(String base, this.token, {http.Client? client})
    : endpoint = _endpoint(base),
      client = client ?? http.Client();

  static Uri _endpoint(String base) {
    final uri = secureEndpoint(base);
    if (uri.hasQuery) throw ArgumentError('Control URL must not have a query');
    final prefix = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(path: '$prefix/streams');
  }

  Future<Map<String, dynamic>> capabilities() => _request(null);

  Future<Map<String, dynamic>> command(
    String operation, [
    Map<String, dynamic> body = const {},
  ]) => _request({...body, 'protocol_version': 1, 'operation': operation});

  Future<Map<String, dynamic>> _request(Map<String, dynamic>? body) async {
    final request = http.Request(body == null ? 'GET' : 'POST', endpoint);
    request.headers.addAll({
      'Authorization': 'Bearer ${token()}',
      'Content-Type': 'application/json',
    });
    if (body != null) request.body = jsonEncode(body);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 10));
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 10),
    )) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) {
        throw const FormatException('stream response size');
      }
      bytes.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('stream response');
    }
    if (response.statusCode != 200) {
      throw LiveStreamError(
        response.statusCode,
        value['error'] is String
            ? value['error'] as String
            : 'stream_unavailable',
      );
    }
    return value;
  }

  void close() => client.close();
}
