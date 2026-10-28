import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/media_routes.dart';
import 'package:voicechat_probe/route_config.dart';
import 'package:voicechat_probe/route_coordinator.dart';
import 'package:voicechat_probe/route_transport.dart';
import 'route_io_test.dart' show serve, endpoint;

class MediaClient implements Client {
  @override
  final RouteTransport httpClient;
  MediaClient(this.httpClient);
  @override
  Uri get homeserver => httpClient.origin;
  @override
  String get accessToken => 'synthetic-token';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'shared media/P2P TURN requests use the route and leave the chat pool usable',
    () async {
      var revision = 0;
      var allowed = true;
      final server = await serve((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/health/route') {
          request.response.write(
            jsonEncode({
              'schema': 1,
              'service_id': 'media-test',
              'edge_id': 'a',
              'age_ms': 0,
              'matrix': true,
              'control': true,
            }),
          );
        } else if (request.uri.path.endsWith('/voip/turnServer')) {
          expect(
            request.headers.value('authorization'),
            'Bearer synthetic-token',
          );
          request.response.write(
            jsonEncode({
              'username': 'user-${++revision}',
              'password': 'temporary',
              'ttl': 600,
              'uris': [
                if (allowed) 'turn:turn-a.localhost:3478',
                'turn:unknown.localhost:3478',
              ],
            }),
          );
        } else {
          request.response.write('{"versions":["v1.1"]}');
        }
        await request.response.close();
      });
      final config = RouteConfig.parse(
        jsonEncode({
          'schema': 1,
          'service_id': 'media-test',
          'matrix_server_name': 'media.localhost',
          'canonical_origin': 'http://localhost:9',
          'web_origins': ['http://localhost:9'],
          'edges': [
            {
              'id': 'a',
              'origin': endpoint(server).toString(),
              'turn_host': 'turn-a.localhost',
            },
          ],
        }),
      );
      final coordinator = RouteCoordinator(config);
      addTearDown(coordinator.close);
      await coordinator.refresh();
      final transport = RouteTransport(
        origin: config.canonicalOrigin,
        routes: [endpoint(server)],
        inner: http.Client(),
        coordinator: coordinator,
      );
      addTearDown(transport.close);
      final client = MediaClient(transport);
      for (final number in [1, 2]) {
        final servers = await mediaIceServers(client);
        expect(servers.single['username'], 'user-$number');
        expect(servers.single['urls'], ['turn:turn-a.localhost:3478']);
      }
      allowed = false;
      await expectLater(mediaIceServers(client), throwsFormatException);
      final response = await transport.get(
        config.canonicalOrigin.resolve('/_matrix/client/versions'),
      );
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body)['versions'], ['v1.1']);
    },
  );
}
