import 'dart:async';
import 'dart:convert';
import 'route_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicechat_probe/route_config.dart';
import 'package:voicechat_probe/route_coordinator.dart';
import 'package:voicechat_probe/route_transport.dart';
import 'route_transport_test.dart' show StreamingClient;

RouteConfig config() =>
    RouteConfig.parse(routeFixture('three-vps.example.json'));

http.Response health(
  http.Request request, {
  bool matrix = true,
  bool control = true,
  Map<String, dynamic> override = const {},
}) {
  expect(request.headers.containsKey('authorization'), false);
  expect(request.followRedirects, false);
  return http.Response(
    jsonEncode({
      'schema': 1,
      'service_id': 'voicechat',
      'edge_id': request.url.host.startsWith('b.') ? 'b' : 'c',
      'age_ms': 0,
      'matrix': matrix,
      'control': control,
      ...override,
    }),
    matrix && control ? 200 : 503,
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  test(
    'real failures override healthy probes only for the affected service',
    () async {
      final router = RouteCoordinator(
        config(),
        clientFactory: () => MockClient((r) async => health(r)),
      );
      addTearDown(router.close);
      await router.refresh();
      final matrix = router.route(RouteService.matrix)!;
      final control = router.route(RouteService.control)!;
      final signaling = router.route(RouteService.signaling)!;
      await router.reportFailure(RouteService.signaling, signaling.origin);
      expect(router.route(RouteService.signaling)!.id, isNot(signaling.id));
      expect(router.route(RouteService.matrix), matrix);
      expect(router.route(RouteService.control), control);
      await router.refresh();
      expect(router.route(RouteService.signaling)!.id, isNot(signaling.id));
      final second = router.route(RouteService.signaling)!;
      await router.reportFailure(RouteService.signaling, second.origin);
      expect(router.route(RouteService.signaling), signaling);
      await router.reportFailure(RouteService.matrix, matrix.origin);
      expect(router.route(RouteService.matrix)!.id, isNot(matrix.id));
      expect(router.route(RouteService.control), control);
      router.close();
      await router.reportFailure(RouteService.control, control.origin);
      expect(router.state, RouteState.closed);
    },
  );
  test(
    'one co-located entry selects normally and an empty list is still invalid',
    () async {
      final raw = jsonDecode(routeFixture('single-vps.example.json'));
      final single = RouteConfig.parse(jsonEncode(raw));
      expect(single.edges.single.id, 'a');
      expect(single.edges.single.origin, single.canonicalOrigin);
      final router = RouteCoordinator(
        single,
        clientFactory: () => MockClient(
          (request) async => health(request, override: {'edge_id': 'a'}),
        ),
      );
      addTearDown(router.close);
      await router.refresh();
      expect(router.route(RouteService.matrix)!.id, 'a');
      expect(router.route(RouteService.control)!.id, 'a');
      await router.reportFailure(
        RouteService.signaling,
        single.edges.single.origin,
      );
      expect(router.route(RouteService.signaling)!.id, 'a');
      raw['edges'] = [];
      expect(() => RouteConfig.parse(jsonEncode(raw)), throwsFormatException);
    },
  );

  test('D and E are configuration entries, not new client code paths', () {
    final raw = jsonDecode(routeFixture('three-vps.example.json'));
    for (final id in ['d', 'e']) {
      raw['edges'].add({
        'id': id,
        'origin': 'https://$id.example.com',
        'turn_host': 'turn-$id.example.com',
      });
    }
    expect(RouteConfig.parse(jsonEncode(raw)).edges.map((e) => e.id), [
      'b',
      'c',
      'd',
      'e',
    ]);
  });

  test(
    'route loss aborts a pending sync without replaying it or losing its cursor',
    () async {
      var failedB = false;
      final router = RouteCoordinator(
        config(),
        clientFactory: () => MockClient(
          (r) async => health(
            r,
            matrix: failedB
                ? r.url.host.startsWith('c.')
                : r.url.host.startsWith('b.'),
          ),
        ),
      );
      addTearDown(router.close);
      await router.refresh();
      final started = Completer<void>();
      var sent = 0;
      final network = RouteTransport(
        origin: router.config.canonicalOrigin,
        routes: router.config.edges.map((e) => e.origin).toList(),
        coordinator: router,
        inner: StreamingClient((request) async {
          sent++;
          expect(request.url.queryParameters['since'], 'retained');
          if (sent == 1) {
            expect(request.url.host, 'b.example.com');
            started.complete();
            await (request as http.Abortable).abortTrigger;
            throw http.RequestAbortedException();
          }
          expect(request.url.host, 'c.example.com');
          return http.StreamedResponse(Stream.value(utf8.encode('{}')), 200);
        }),
      );
      addTearDown(network.close);
      final url = router.config.canonicalOrigin.resolve(
        '/_matrix/client/v3/sync?since=retained&timeout=30000',
      );
      final pending = expectLater(
        network.get(url),
        throwsA(isA<http.RequestAbortedException>()),
      );
      await started.future;
      failedB = true;
      await router.refresh();
      await pending;
      expect(sent, 1);
      expect((await network.get(url)).statusCode, 200);
      expect(sent, 2);
    },
  );
  test('shared topology fixture and malformed contracts', () {
    final value = config();
    expect(value.edges.map((e) => e.id), ['b', 'c']);
    for (final change in <void Function(Map<String, dynamic>)>[
      (v) => v['schema'] = true,
      (v) => v['schema'] = 2,
      (v) => v['edges'][0]['origin'] = 'http://localhost:8000',
      (v) => v['edges'][0]['origin'] = 'https://u:p@host.test',
      (v) => v['edges'][0]['origin'] = 'https://b.example.com?',
      (v) => v['edges'][0]['origin'] = 'https://b.example.com/',
      (v) => v['edges'][1]['id'] = 'b',
      (v) => v['edges'][0]['secret'] = 'secret',
      (v) => v['web_origins'] = [],
    ]) {
      final raw =
          jsonDecode(routeFixture('three-vps.example.json'))
              as Map<String, dynamic>;
      change(raw);
      expect(
        () => RouteConfig.parse(jsonEncode(raw)),
        throwsA(isA<Exception>()),
      );
    }
  });

  test('availability, median, ties and speed hysteresis', () {
    final edges = config().edges, b = edges[0], c = edges[1];
    RouteSample sample(RouteEdge edge, int ms) =>
        RouteSample(edge, Duration(milliseconds: ms), true, false);
    expect(
      chooseRoute([
        sample(b, 500),
        sample(b, 500),
        sample(c, 20),
      ], RouteService.matrix),
      b,
    );
    expect(
      chooseRoute(
        [sample(b, 200), sample(c, 170)],
        RouteService.matrix,
        previous: b,
      ),
      b,
    );
    expect(
      chooseRoute(
        [sample(b, 1000), sample(c, 900)],
        RouteService.matrix,
        previous: b,
      ),
      b,
    );
    expect(
      chooseRoute(
        [sample(b, 200), sample(c, 150)],
        RouteService.matrix,
        previous: b,
      ),
      c,
    );
    expect(
      chooseRoute(
        [sample(b, 200), sample(c, 20)],
        RouteService.matrix,
        previous: b,
        reconsiderHealthy: false,
      ),
      b,
    );
    expect(
      chooseRoute(
        [sample(b, 20), sample(c, 20)],
        RouteService.matrix,
        previous: c,
      ),
      c,
    );
    expect(chooseRoute([sample(b, 20)], RouteService.control), isNull);
  });

  test(
    'parallel probes coalesce and partial readiness routes services independently',
    () async {
      final gate = Completer<void>();
      var entered = 0;
      final router = RouteCoordinator(
        config(),
        clientFactory: () => MockClient((request) async {
          entered++;
          await gate.future;
          return health(
            request,
            matrix: request.url.host.startsWith('b.'),
            control: request.url.host.startsWith('c.'),
          );
        }),
      );
      addTearDown(router.close);
      final first = router.refresh();
      final second = router.refresh();
      expect(identical(first, second), true);
      await Future<void>.delayed(Duration.zero);
      expect(entered, 2); // Neither edge waits for the other edge's timeout.
      gate.complete();
      await first;
      expect(entered, 4);
      expect(router.route(RouteService.matrix)!.id, 'b');
      expect(router.route(RouteService.control)!.id, 'c');
      final network = RouteTransport(
        origin: router.config.canonicalOrigin,
        routes: router.config.edges.map((e) => e.origin).toList(),
        coordinator: router,
        inner: MockClient(
          (request) async => http.Response(request.url.host, 200),
        ),
      );
      addTearDown(network.close);
      expect(
        (await network.get(
          router.config.canonicalOrigin.resolve('/_matrix/client/versions'),
        )).body,
        'b.example.com',
      );
      expect(
        (await network.get(
          router.config.canonicalOrigin.resolve('/api/screen/state'),
        )).body,
        'c.example.com',
      );
    },
  );

  test(
    'wrong identity, stale data, captive portal, redirect and oversized responses are rejected',
    () async {
      for (final bad in <http.Response Function(http.Request)>[
        (r) => health(r, override: {'service_id': 'foreign'}),
        (r) => health(r, override: {'edge_id': 'foreign'}),
        (r) => health(r, override: {'age_ms': 2001}),
        (r) => health(r, override: {'age_ms': -1}),
        (r) => health(r, override: {'matrix': 'true'}),
        (r) => http.Response('<html>portal</html>', 200),
        (r) => http.Response(
          '',
          302,
          headers: {'location': 'https://elsewhere.test'},
        ),
        (r) => http.Response(
          ' ' * 4097,
          200,
          headers: {'content-type': 'application/json'},
        ),
      ]) {
        final router = RouteCoordinator(
          config(),
          clientFactory: () => MockClient((r) async => bad(r)),
        );
        await router.refresh();
        expect(router.state, RouteState.unavailable);
        router.close();
      }
    },
  );

  test('late probes cannot restore a disposed session', () async {
    final gate = Completer<void>();
    final router = RouteCoordinator(
      config(),
      clientFactory: () => MockClient((r) async {
        await gate.future;
        return health(r);
      }),
    );
    final pending = router.refresh();
    router.close();
    gate.complete();
    await pending;
    expect(router.state, RouteState.closed);
    expect(router.route(RouteService.matrix), isNull);
  });

  test(
    'lost mutation is not replayed; auth/rate limits do not initiate route checks',
    () async {
      var checks = 0, writes = 0;
      var failB = false;
      final router = RouteCoordinator(
        config(),
        clientFactory: () => MockClient((r) async {
          checks++;
          return health(r, matrix: !failB || r.url.host.startsWith('c.'));
        }),
      );
      addTearDown(router.close);
      await router.refresh();
      var status = 401;
      final network = RouteTransport(
        origin: router.config.canonicalOrigin,
        routes: router.config.edges.map((e) => e.origin).toList(),
        coordinator: router,
        inner: MockClient((r) async {
          writes++;
          if (status == 0) {
            failB = true;
            throw http.ClientException('lost response');
          }
          return http.Response('', status, headers: {'retry-after': '15'});
        }),
      );
      addTearDown(network.close);
      for (final code in [401, 403, 429]) {
        status = code;
        final response = await network.post(
          router.config.canonicalOrigin.resolve('/_matrix/action'),
        );
        expect(response.statusCode, code);
        expect(response.headers['retry-after'], '15');
      }
      expect(checks, 4);
      status = 0;
      await expectLater(
        network.post(router.config.canonicalOrigin.resolve('/_matrix/action')),
        throwsA(isA<http.ClientException>()),
      );
      await router.refresh();
      expect(writes, 4);
      expect(checks, 8);
      expect(router.route(RouteService.matrix)!.id, 'c');
    },
  );

  test(
    'two hanging edges finish within the 3.5 second selection budget',
    () async {
      final router = RouteCoordinator(
        config(),
        clientFactory: () =>
            MockClient((_) => Completer<http.Response>().future),
      );
      addTearDown(router.close);
      final clock = Stopwatch()..start();
      await router.refresh();
      expect(router.state, RouteState.unavailable);
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 3500)));
    },
  );
}
