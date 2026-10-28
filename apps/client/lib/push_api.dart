import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'transport.dart';
import 'user_action_error.dart';

/// Uses the caller's routed client; mutations are never replayed on another edge.
Future<String> requestPush(
  http.Client client,
  String base,
  String token,
  String path,
  String? body,
) async {
  if (!{'config', 'subscribe'}.contains(path) ||
      (path == 'config') != (body == null)) {
    throw const FormatException('Invalid push request');
  }
  final url = secureEndpoint(base);
  if (url.hasQuery || url.hasFragment) {
    throw const FormatException('Invalid push API base');
  }
  final request = http.Request(
    body == null ? 'GET' : 'POST',
    url.replace(path: '${url.path.replaceFirst(RegExp(r"/$"), "")}/push/$path'),
  )..followRedirects = false;
  request.headers.addAll({
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  });
  if (body != null) request.body = body;
  final response = await (() async {
    return http.Response.fromStream(await client.send(request));
  })().timeout(const Duration(seconds: 15));
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw UserActionError('Сервис уведомлений недоступен. Повторите позже.');
  }
  if (jsonDecode(response.body) is! Map<String, dynamic>) {
    throw const FormatException('Invalid push response');
  }
  return response.body;
}
