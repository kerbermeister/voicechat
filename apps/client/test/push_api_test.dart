import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicechat_probe/push_api.dart';
import 'package:voicechat_probe/route_transport.dart';

void main() {
  final canonical = Uri.parse('https://core.example');
  final first = Uri.parse('https://b.example');
  final second = Uri.parse('https://c.example');

  test(
    'Push config and subscription use the selected entry with no replay or redirect',
    () async {
      final requests = <http.Request>[];
      var status = 200;
      final network = RouteTransport(
        origin: canonical,
        routes: [first, second],
        inner: MockClient((request) async {
          requests.add(request);
          expect(request.followRedirects, false);
          expect(request.headers['Authorization'], 'Bearer fixture-token');
          return http.Response('{"binding":"fixture-binding"}', status);
        }),
      );
      addTearDown(network.close);
      final response = await requestPush(
        network,
        '$canonical/api',
        'fixture-token',
        'config',
        null,
      );
      expect(jsonDecode(response)['binding'], 'fixture-binding');
      expect(
        requests.single.url.toString(),
        'https://b.example/api/push/config',
      );
      network.select(second);
      const body =
          '{"action":"register","subscription":{"endpoint":"fixture"}}';
      await requestPush(
        network,
        '$canonical/api/',
        'fixture-token',
        'subscribe',
        body,
      );
      expect(
        requests.last.url.toString(),
        'https://c.example/api/push/subscribe',
      );
      expect(requests.last.method, 'POST');
      expect(requests.last.body, body);
      status = 503;
      await expectLater(
        requestPush(
          network,
          '$canonical/api',
          'fixture-token',
          'subscribe',
          '{"action":"remove"}',
        ),
        throwsA(anything),
      );
      expect(requests.length, 3);
      status = 307;
      await expectLater(
        requestPush(network, '$canonical/api', 'fixture-token', 'config', null),
        throwsA(anything),
      );
      expect(requests.length, 4);
    },
  );

  test('Unexpected endpoint, body, base and response fail closed', () async {
    var count = 0;
    final client = MockClient((request) async {
      count++;
      return http.Response('[]', 200);
    });
    addTearDown(client.close);
    for (final entry in [
      ('config/../../token', null),
      ('config', '{}'),
      ('subscribe', null),
    ]) {
      await expectLater(
        requestPush(client, '$canonical/api', 'fixture', entry.$1, entry.$2),
        throwsFormatException,
      );
    }
    await expectLater(
      requestPush(
        client,
        '$canonical/api?foreign=true',
        'fixture',
        'config',
        null,
      ),
      throwsFormatException,
    );
    expect(count, 0);
    await expectLater(
      requestPush(client, '$canonical/api', 'fixture', 'config', null),
      throwsFormatException,
    );
    expect(count, 1);
  });
}
