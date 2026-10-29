import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:integration_test/integration_test.dart';
import 'package:voicechat_probe/route_config.dart';
import 'route_catalog_probe.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('signed discovery survives unreachable cached API entries', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await vod.init();
      final topology = <String, dynamic>{
        'schema': 1,
        'service_id': 'catalog-native',
        'matrix_server_name': 'routes.test',
        'canonical_origin': 'http://localhost:9',
        'web_origins': ['http://localhost:9'],
        'edges': [
          {
            'id': 'b',
            'origin': 'http://127.0.0.1:9',
            'turn_host': 'turn-b.localhost',
          },
        ],
      };
      checkSignedCatalog(RouteConfig.parse(jsonEncode(topology)), topology);
      await checkCatalogDiscovery();
    });
  });
}
