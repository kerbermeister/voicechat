// Local acceptance entrypoint, never the production application target.
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vodozemac/vodozemac.dart' as crypto;
import 'package:web/web.dart' as web;
import 'package:voicechat_probe/route_catalog.dart';
import 'package:voicechat_probe/route_config.dart';

void require(bool value, String message) {
  // Release builds omit assert: these checks must remain executable.
  if (!value) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final input = jsonDecode(const String.fromEnvironment('ROUTE_WEB_PROBE'));
    final origin = Uri.parse(input['origin'] as String);
    final bootstrap = RouteConfig.parse(jsonEncode(input['bootstrap']));
    final key = input['key'] as String;
    final storageKey = 'route-catalog:${bootstrap.serviceId}:$key';
    final accountKey = 'probe-account:${bootstrap.serviceId}';
    await crypto
        .init(wasmPath: origin.resolve('/pkg/').toString())
        .timeout(const Duration(seconds: 20));
    final preferences = await SharedPreferences.getInstance();
    final catalog = RouteCatalog(bootstrap, key, preferences);
    Future<void> phase(String name) async {
      final response = await http.post(origin.resolve('/fixture/$name'));
      require(response.statusCode == 200, 'Fixture phase failed');
    }

    bool discovered() =>
        catalog.config.edges.map((e) => e.id).join(',') == 'b,d';
    try {
      if (Uri.base.queryParameters['reopen'] == '1') {
        require(
          catalog.current?.revision == 4 && discovered(),
          'Reload lost verified catalog',
        );
        await catalog
            .refresh(); // Both fixture entries remain offline after phase one.
        require(
          catalog.current?.revision == 4 && discovered(),
          'Offline reload lost D',
        );
        await phase('rollback');
        await catalog.refresh();
        require(
          catalog.current?.revision == 4,
          'Rollback accepted after real page reload',
        );
        require(
          preferences.getString(accountKey) == 'preserved',
          'Unrelated account state changed',
        );
        final status = jsonDecode(
          (await http.get(origin.resolve('/fixture/status'))).body,
        );
        require(
          status['requests']['d'] > 0,
          'Discovered D was never requested',
        );
        require(
          status['credentials_seen'] == false,
          'Catalog requests carried credentials',
        );
      } else {
        await preferences.setString(accountKey, 'preserved');
        final response = await http.get(
          origin.resolve('/.well-known/voicechat/routes.json'),
        );
        require(response.statusCode == 200, 'Initial fixture HTTP failed');
        require(
          verifyRouteCatalog(response.body, key, bootstrap).revision == 2,
          'WASM signature failed',
        );
        require(
          catalog.config.edges.length == 1,
          'Bootstrap must contain only B',
        );
        await catalog.refresh();
        require(
          catalog.current?.revision == 2 && discovered(),
          'Signed discovery failed',
        );
        require(
          web.window.localStorage.getItem('flutter.$storageKey') != null,
          'Real localStorage record missing',
        );
        final cached = preferences.getString(storageKey);
        for (final invalid in [
          'rollback',
          'tampered',
          'expired',
          'foreign',
          'offline',
        ]) {
          await phase(invalid);
          await catalog.refresh();
          require(
            catalog.current?.revision == 2 &&
                preferences.getString(storageKey) == cached,
            'Invalid catalog accepted: $invalid',
          );
        }
        await phase('conflict');
        var rejected = false;
        try {
          await catalog.refresh();
        } on FormatException {
          rejected = true;
        }
        require(
          rejected && preferences.getString(storageKey) == cached,
          'Conflicting revision was accepted',
        );
        await phase('advance');
        await catalog.refresh();
        require(
          catalog.current?.revision == 4,
          'New valid revision was not persisted',
        );
        await phase('offline');
      }
    } finally {
      catalog.close();
    }
    web.document.body!.dataset['routeResult'] = jsonEncode({
      'ok': true,
      'revision': 4,
    });
  } catch (error) {
    web.document.body!.dataset['routeResult'] = jsonEncode({
      'ok': false,
      'error': '$error',
    });
  }
}
