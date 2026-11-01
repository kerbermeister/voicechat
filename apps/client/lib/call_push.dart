import 'dart:async';
import 'dart:convert';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'transport.dart';

class CallPushError implements Exception {
  final int status;
  final String code;
  const CallPushError(this.status, this.code);
}

/// Push carries no SDP or keys; encrypted Matrix signalling remains authoritative.
class CallPush {
  final Client client;
  final String base;
  CallPush(this.client, this.base) {
    secureEndpoint(base);
  }

  Future<Map<String, dynamic>> request(
    String action,
    String session, {
    String? room,
  }) async {
    final request = http.Request('POST', Uri.parse('$base/push/call'))
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${client.accessToken}',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({
        'action': action,
        'session': session,
        if (room != null) 'room': room,
      });
    final response = await client.httpClient
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 10));
    if (response.bodyBytes.length > 8192) throw const FormatException();
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw CallPushError(
        response.statusCode,
        body['error'] as String? ?? 'unavailable',
      );
    }
    return body;
  }
}
