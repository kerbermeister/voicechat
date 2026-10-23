import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'transport.dart';

class ScreenApiError implements Exception {
  final int status;
  final String code;
  const ScreenApiError(this.status, this.code);
}

String screenRequestId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Владеет только своим HTTP-клиентом; bearer не попадает в URL и диагностику.
class ScreenApi {
  final String base;
  final String Function() token;
  final http.Client client;
  ScreenApi(this.base, this.token, {http.Client? client})
    : client = client ?? http.Client() {
    secureEndpoint(base);
  }

  Future<Map<String, dynamic>> request(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse('$base/screen/$path');
    final headers = {
      'Authorization': 'Bearer ${token()}',
      'Content-Type': 'application/json',
    };
    final response =
        await (body == null
                ? client.get(uri, headers: headers)
                : client.post(uri, headers: headers, body: jsonEncode(body)))
            .timeout(const Duration(seconds: 10));
    if (response.bodyBytes.length > 32768) {
      throw const FormatException('screen response size');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('screen response');
    }
    if (response.statusCode != 200 && response.statusCode != 202) {
      throw ScreenApiError(
        response.statusCode,
        json['error'] is String ? json['error'] : 'screen_unavailable',
      );
    }
    return json;
  }

  void close() => client.close();
}
