import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:voicechat_probe/call_page_exit.dart';
import 'package:voicechat_probe/route_transport.dart';

// Local synthetic traffic only. The receiver checks both writes after navigating away.
void main() {
  final origin = Uri.parse(Uri.base.origin);
  final network = RouteTransport(
    origin: origin,
    routes: [origin],
    inner: http.Client(),
  );
  listenCallPageExit(() {
    for (final request in [
      http.Request('POST', origin.resolve('/api/call/leave'))
        ..body = jsonEncode({'lease_id': 'fixture-lease'}),
      http.Request(
        'PUT',
        origin.resolve(
          '/_matrix/client/v3/rooms/fixture/send/m.room.encrypted/exit',
        ),
      )..body = jsonEncode({'ciphertext': 'synthetic-encrypted-hangup'}),
    ]) {
      request.headers['Authorization'] = 'Bearer fixture-token';
      request.headers['Content-Type'] = 'application/json';
      unawaited(
        network
            .send(request)
            .catchError(
              (Object _) => http.StreamedResponse(const Stream.empty(), 599),
            ),
      );
    }
  });
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text(
            'Exit fixture ready. Navigate away; the local receiver verifies both requests.',
          ),
        ),
      ),
    ),
  );
}
