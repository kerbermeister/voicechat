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
  final _outgoing = <String, Future<Map<String, dynamic>>>{};
  final _ending = <String, Future<void>>{};
  CallPush(this.client, this.base) {
    secureEndpoint(base);
  }

  Future<void> invite(String session, String room, {bool video = false}) async {
    final pending = request('invite', session, room: room, video: video);
    _outgoing[session] = pending;
    await pending;
  }

  Future<void> endOutgoing(String session) {
    final ending = _ending[session];
    if (ending != null) return ending;
    final invite = _outgoing[session];
    if (invite == null) return Future.value();
    final completed = () async {
      // Even a lost invite response can mean the server has started ringing.
      try {
        await invite;
      } catch (_) {
        /* Still send the matching cancellation. */
      }
      try {
        await request('end', session);
      } catch (_) {
        // Server-side expiry remains the upper bound when the network is down.
      } finally {
        _outgoing.remove(session);
        _ending.remove(session);
      }
    }();
    _ending[session] = completed;
    return completed;
  }

  Future<void> endAll() async {
    await Future.wait(_outgoing.keys.toList().map(endOutgoing));
  }

  Future<Map<String, dynamic>> request(
    String action,
    String session, {
    String? room,
    bool? video,
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
        if (video != null) 'video': video,
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
