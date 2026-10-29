import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vodozemac/vodozemac.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/route_catalog.dart';
import 'package:voicechat_probe/route_config.dart';

void checkSignedCatalog(RouteConfig bootstrap, Map<String, dynamic> topology) {
  final signer = crypto.PkSigning();
  final key = base64Encode(signer.publicKey.toBytes());
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String signed(int revision, {int? expires, String? service}) {
    final value = jsonDecode(jsonEncode(topology));
    if (service != null) value['service_id'] = service;
    final payload = jsonEncode({
      'schema': 1,
      'revision': revision,
      'issued_at': now - 10,
      'expires_at': expires ?? now + 3600,
      'topology': value,
    });
    return jsonEncode({
      'payload': base64Encode(utf8.encode(payload)),
      'signature': base64Encode(
        signer.sign(routeCatalogDomain + payload).toBytes(),
      ),
    });
  }

  final current = verifyRouteCatalog(signed(2), key, bootstrap);
  expect(current.revision, 2);
  expect(
    () => verifyRouteCatalog(signed(1), key, bootstrap, previous: current),
    throwsFormatException,
  );
  expect(
    () => verifyRouteCatalog(
      signed(2, expires: now + 2000),
      key,
      bootstrap,
      previous: current,
    ),
    throwsFormatException,
  );
  expect(
    () => verifyRouteCatalog(signed(3, service: 'foreign'), key, bootstrap),
    throwsFormatException,
  );
  expect(
    () => verifyRouteCatalog(signed(3, expires: now - 1), key, bootstrap),
    throwsFormatException,
  );
  expect(
    verifyRouteCatalog(
      signed(2, expires: now - 1),
      key,
      bootstrap,
      restoring: true,
    ).revision,
    2,
  );
  final tampered = jsonDecode(signed(3));
  tampered['payload'] = base64Encode(utf8.encode('{}'));
  expect(
    () => verifyRouteCatalog(jsonEncode(tampered), key, bootstrap),
    throwsA(anything),
  );
  expect(
    () => verifyRouteCatalog(
      signed(3),
      base64Encode(crypto.PkSigning().publicKey.toBytes()),
      bootstrap,
    ),
    throwsA(anything),
  );
}

Future<void> checkCatalogDiscovery({bool websiteOnly = false}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final mirror = 'http://127.0.0.1:${server.port}';
  final service = 'discovery-${DateTime.now().microsecondsSinceEpoch}';
  final signer = crypto.PkSigning();
  final key = base64Encode(signer.publicKey.toBytes());
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final bootstrapJson = {
    'schema': 1,
    'service_id': service,
    'matrix_server_name': 'routes.test',
    'canonical_origin': 'http://localhost:9',
    'web_origins': ['http://localhost:9', if (!websiteOnly) mirror],
    'edges': [
      {
        'id': 'b',
        'origin': 'http://127.0.0.1:9',
        'turn_host': 'turn-b.localhost',
      },
    ],
  };
  String signed(int revision, String edge, String origin) {
    final payload = jsonEncode({
      'schema': 1,
      'revision': revision,
      'issued_at': now - 10,
      'expires_at': now + 3600,
      'topology': {
        ...bootstrapJson,
        // Only the compiled bootstrap retains the reachable mirror after the
        // first update. Neither cached API entry has a listening server.
        'web_origins': ['http://localhost:9'],
        'edges': [
          {'id': edge, 'origin': origin, 'turn_host': 'turn-$edge.localhost'},
        ],
      },
    });
    return jsonEncode({
      'payload': base64Encode(utf8.encode(payload)),
      'signature': base64Encode(
        signer.sign(routeCatalogDomain + payload).toBytes(),
      ),
    });
  }

  var response = signed(1, 'd', 'http://127.0.0.1:9');
  var requests = 0;
  final listener = server.listen((request) async {
    expect(request.method, 'GET');
    expect(request.uri.path, '/.well-known/voicechat/routes.json');
    expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
    requests++;
    request.response.headers.contentType = ContentType.json;
    request.response.write(response);
    await request.response.close();
  });
  final preferences = await SharedPreferences.getInstance();
  for (final invalid in [
    'http://entry.example',
    'https://fixture-user@entry.example',
    'https://entry.example/catalog',
  ]) {
    expect(
      () => RouteCatalog(
        RouteConfig.parse(jsonEncode(bootstrapJson)),
        key,
        preferences,
        discoveryOrigin: Uri.parse(invalid),
      ),
      throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
    );
  }
  final catalog = RouteCatalog(
    RouteConfig.parse(jsonEncode(bootstrapJson)),
    key,
    preferences,
    discoveryOrigin: websiteOnly ? Uri.parse(mirror) : null,
  );
  try {
    if (websiteOnly) {
      response = '{}';
      expect((await catalog.refresh()).edges.single.id, 'b');
      expect(
        catalog.current,
        isNull,
        reason: 'A website cannot authorize an unsigned API route',
      );
      response = signed(1, 'd', 'http://127.0.0.1:9');
    }
    final initialRequests = requests;
    expect((await catalog.refresh()).edges.single.id, 'd');
    response = signed(2, 'e', mirror);
    expect((await catalog.refresh()).edges.single.id, 'e');
    expect(catalog.current!.revision, 2);
    expect(
      requests - initialRequests,
      2,
      reason: 'The known mirror is fetched once per refresh',
    );
    response = jsonEncode({
      'payload': base64Encode(utf8.encode('{}')),
      'signature': '',
    });
    expect((await catalog.refresh()).edges.single.id, 'e');
    expect(
      catalog.current!.revision,
      2,
      reason: 'Discovery cannot bypass signature/high-water checks',
    );
  } finally {
    catalog.close();
    await preferences.remove('route-catalog:$service:$key');
    await server.close(force: true);
    await listener.cancel();
  }
}
