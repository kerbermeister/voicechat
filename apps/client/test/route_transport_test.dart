import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix_api_lite.dart';
import 'package:matrix/matrix.dart' show FixedTimeoutHttpClient;
import 'package:voicechat_probe/route_transport.dart';

final origin = Uri.parse('https://chat.example.org');
final b = Uri.parse('https://b.example.org');
final c = Uri.parse('https://c.example.org');

RouteTransport transport(http.Client inner) =>
    RouteTransport(origin: origin, routes: [b, c], inner: inner);

class StreamingClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  int closes = 0;
  StreamingClient(this.handler);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
  @override
  void close() => closes++;
}

void main() {
  test('finds routed transport through Matrix timeout adapters only', () {
    final inner = MockClient((_) async => http.Response('{}', 200));
    final routed = transport(inner);
    addTearDown(routed.close);
    expect(routeTransportOf(null), isNull);
    expect(routeTransportOf(inner), isNull);
    expect(routeTransportOf(routed), same(routed));
    expect(
      routeTransportOf(
        FixedTimeoutHttpClient(
          FixedTimeoutHttpClient(routed, const Duration(seconds: 5)),
          const Duration(seconds: 10),
        ),
      ),
      same(routed),
    );
  });

  test(
    'Matrix identity and transaction stay canonical when the route changes',
    () async {
      final seen = <http.Request>[];
      final network = transport(
        MockClient((request) async {
          seen.add(request);
          return http.Response('{"event_id":"event"}', 200);
        }),
      );
      addTearDown(network.close);
      final matrix = MatrixApi(
        homeserver: origin,
        accessToken: 'test-token',
        httpClient: network,
      );
      final action =
          '/client/v3/rooms/!room:example.org/send/m.room.encrypted/fixed-transaction';
      final body = {
        'ciphertext': 'unchanged',
        'algorithm': 'm.megolm.v1.aes-sha2',
      };
      await matrix.request(
        RequestType.PUT,
        action,
        data: body,
        query: {'key': 'a+b /'},
      );
      network.select(c);
      await matrix.request(
        RequestType.PUT,
        action,
        data: body,
        query: {'key': 'a+b /'},
      );
      expect(seen.map((r) => r.url.origin), [b.origin, c.origin]);
      expect(seen[0].url.path, seen[1].url.path);
      expect(seen[0].url.query, seen[1].url.query);
      expect(seen[0].bodyBytes, seen[1].bodyBytes);
      expect(seen[1].headers['authorization'], 'Bearer test-token');
      expect(matrix.homeserver, origin);
      expect(matrix.accessToken, 'test-token');
    },
  );

  test(
    'untrusted origins and routes are rejected before consuming the body',
    () async {
      var sent = 0;
      final network = transport(
        MockClient((_) async {
          sent++;
          return http.Response('', 200);
        }),
      );
      addTearDown(network.close);
      for (final url in [
        'https://other.example.org/api',
        'https://u:p@chat.example.org/api',
        '${origin.origin}/api#secret',
      ]) {
        final request = http.Request('POST', Uri.parse(url));
        await expectLater(
          network.send(request),
          throwsA(isA<http.ClientException>()),
        );
        expect(request.finalized, false);
      }
      expect(
        () => network.select(Uri.parse('https://other.example.org')),
        throwsArgumentError,
      );
      expect(sent, 0);
    },
  );

  test(
    'redirect, auth failure and server failure are returned without replay',
    () async {
      for (final status in [302, 307, 401, 403, 429, 502, 503]) {
        var sent = 0;
        final network = transport(
          MockClient((request) async {
            sent++;
            expect(request.followRedirects, false);
            expect(request.maxRedirects, 0);
            expect(request.headers.containsKey('host'), false);
            return http.Response(
              '',
              status,
              headers: {
                'location': 'https://other.example.org',
                'retry-after': '12',
              },
            );
          }),
        );
        final response = await network.post(
          origin.resolve('/api/action'),
          headers: {'host': 'old.example.org'},
          body: 'private',
        );
        expect(response.statusCode, status);
        expect(response.headers['retry-after'], '12');
        expect(response.request!.url.origin, origin.origin);
        expect(sent, 1);
        network.close();
      }
    },
  );

  test('a lost mutation response is not automatically repeated on C', () async {
    var commits = 0;
    final network = transport(
      MockClient((_) async {
        commits++;
        throw http.ClientException('response lost after commit');
      }),
    );
    addTearDown(network.close);
    await expectLater(
      network.post(origin.resolve('/api/action'), body: 'one'),
      throwsA(isA<http.ClientException>()),
    );
    expect(commits, 1);
    expect(network.selected, b);
  });

  test(
    'streaming upload stays on its initial route and preserves cancellation',
    () async {
      final abort = Completer<void>();
      final reached = Completer<void>();
      final body = StreamController<List<int>>();
      final network = transport(
        StreamingClient((request) async {
          expect(request.url.origin, b.origin);
          expect((request as http.Abortable).abortTrigger, same(abort.future));
          reached.complete();
          final bytes = await request.finalize().toBytes();
          expect(bytes, [1, 2, 3, 4]);
          return http.StreamedResponse(Stream.value([5]), 200);
        }),
      );
      addTearDown(network.close);
      final request = http.AbortableStreamedRequest(
        'POST',
        origin.resolve('/_matrix/media/v3/upload'),
        abortTrigger: abort.future,
      );
      final piping = request.sink
          .addStream(body.stream)
          .then((_) => request.sink.close());
      final pending = network.send(request);
      await reached.future;
      network.select(c);
      body.add([1, 2]);
      body.add([3, 4]);
      await body.close();
      await piping;
      expect(await (await pending).stream.toBytes(), [5]);
      expect(network.selected, c);
    },
  );

  test('multipart boundary and body length survive routing', () async {
    final network = transport(
      StreamingClient((request) async {
        expect(
          request.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        final bytes = await request.finalize().toBytes();
        expect(bytes.length, request.contentLength);
        expect(utf8.decode(bytes), contains('sample-content'));
        return http.StreamedResponse(const Stream.empty(), 200);
      }),
    );
    addTearDown(network.close);
    final request = http.MultipartRequest('POST', origin.resolve('/api/upload'))
      ..files.add(
        http.MultipartFile.fromString(
          'file',
          'sample-content',
          filename: 'sample.txt',
        ),
      );
    await network.send(request);
    expect(request.finalized, true);
    await expectLater(network.send(request), throwsStateError);
  });

  test('invalid route configuration and TLS downgrade are rejected', () {
    final inner = MockClient((_) async => http.Response('', 200));
    addTearDown(inner.close);
    for (final routes in <List<Uri>>[
      [],
      [b, b],
      [b, Uri.parse('http://remote.example.org')],
      [b, Uri.parse('http://localhost:8000')],
      [b, Uri.parse('https://c.example.org/path')],
      [b, Uri.parse('https://c.example.org?')],
      [b, Uri.parse('https://c.example.org:0')],
    ]) {
      expect(
        () => RouteTransport(origin: origin, routes: routes, inner: inner),
        throwsArgumentError,
      );
    }
  });

  test(
    'close owns its client exactly once and prevents later requests',
    () async {
      final inner = StreamingClient(
        (_) async => http.StreamedResponse(const Stream.empty(), 200),
      );
      final network = transport(inner);
      network.close();
      network.close();
      expect(inner.closes, 1);
      expect(() => network.select(c), throwsStateError);
      await expectLater(network.get(origin), throwsStateError);
    },
  );
}
