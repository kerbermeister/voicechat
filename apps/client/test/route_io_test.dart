import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:voicechat_probe/route_transport.dart';

final canonical = Uri.parse('http://localhost:65000');

Future<HttpServer> serve(Future<void> Function(HttpRequest) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  addTearDown(() => server.close(force: true));
  return server;
}

Uri endpoint(HttpServer server) => Uri.parse('http://127.0.0.1:${server.port}');

RouteTransport network(HttpServer b, HttpServer c) {
  final result = RouteTransport(
    origin: canonical,
    routes: [endpoint(b), endpoint(c)],
    inner: IOClient(HttpClient()..findProxy = (_) => 'DIRECT'),
  );
  addTearDown(result.close);
  return result;
}

void main() {
  test(
    'fork keeps the selected entry and closes only its own socket pool',
    () async {
      var bRequests = 0, cRequests = 0;
      final b = await serve((request) async {
        bRequests++;
        await request.response.close();
      });
      final c = await serve((request) async {
        cRequests++;
        request.response.write('through-c');
        await request.response.close();
      });
      final routes = network(b, c)..select(endpoint(c));
      final fork = routes.fork();
      addTearDown(fork.close);
      expect(
        (await fork.get(
          canonical.resolve('/updates/android/latest.json'),
        )).body,
        'through-c',
      );
      fork.close();
      expect(
        (await routes.get(canonical.resolve('/_matrix/client/versions'))).body,
        'through-c',
      );
      expect(bRequests, 0);
      expect(cRequests, 2);
    },
  );

  test(
    'socket upload finishes on B after route selection changes to C',
    () async {
      final firstChunk = Completer<void>();
      final received = BytesBuilder();
      var uploads = 0, cRequests = 0;
      final b = await serve((request) async {
        expect(
          request.uri.toString(),
          '/_matrix/media/v3/upload?filename=test.bin',
        );
        expect(
          request.headers.value('authorization'),
          'Bearer test-only-token',
        );
        await for (final block in request) {
          received.add(block);
          if (!firstChunk.isCompleted) firstChunk.complete();
        }
        uploads++;
        request.response.write('{"content_uri":"mxc://stable.test/object"}');
        await request.response.close();
      });
      final c = await serve((request) async {
        cRequests++;
        expect(request.method, 'GET');
        request.response.write('through-c');
        await request.response.close();
      });
      final routes = network(b, c);
      final request = http.StreamedRequest(
        'POST',
        canonical.resolve('/_matrix/media/v3/upload?filename=test.bin'),
      )..headers['authorization'] = 'Bearer test-only-token';
      final pending = routes.send(request);
      request.sink.add(List.filled(32768, 17));
      await firstChunk.future.timeout(const Duration(seconds: 5));
      routes.select(endpoint(c));
      request.sink.add(List.filled(32768, 29));
      await request.sink.close();
      expect(
        await (await pending).stream.bytesToString(),
        contains('mxc://stable.test/object'),
      );
      expect(received.takeBytes(), [
        ...List.filled(32768, 17),
        ...List.filled(32768, 29),
      ]);
      expect(uploads, 1);
      expect(cRequests, 0);
      expect(
        (await routes.get(canonical.resolve('/api/check'))).body,
        'through-c',
      );
      expect(cRequests, 1);
    },
  );

  test(
    'socket loss after committed mutation never replays on another entry',
    () async {
      var commits = 0, cRequests = 0;
      final b = await serve((request) async {
        expect(await utf8.decoder.bind(request).join(), 'one-operation');
        commits++;
        final socket = await request.response.detachSocket(writeHeaders: false);
        await socket.close();
      });
      final c = await serve((request) async {
        cRequests++;
        await request.response.close();
      });
      final routes = network(b, c);
      await expectLater(
        routes.post(canonical.resolve('/api/action'), body: 'one-operation'),
        throwsA(isA<http.ClientException>()),
      );
      routes.select(endpoint(c));
      expect(commits, 1);
      expect(cRequests, 0);
    },
  );
}
