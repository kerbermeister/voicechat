import 'dart:convert';
import 'route_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:voicechat_probe/route_config.dart';
import 'package:voicechat_probe/route_coordinator.dart';
import 'package:voicechat_probe/route_status_banner.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'network status preserves draft/focus and fits enlarged text in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        var available = false, control = false;
        final router = RouteCoordinator(
          RouteConfig.parse(routeFixture('three-vps.example.json')),
          clientFactory: () => MockClient(
            (r) async => http.Response(
              jsonEncode({
                'schema': 1,
                'service_id': 'voicechat',
                'edge_id': r.url.host.startsWith('b.') ? 'b' : 'c',
                'age_ms': 0,
                'matrix': available,
                'control': control,
              }),
              available && control ? 200 : 503,
              headers: {'content-type': 'application/json'},
            ),
          ),
        );
        addTearDown(router.close);
        // Browser stream callbacks must run outside the widget fake clock.
        await tester.runAsync(router.refresh);
        final draft = TextEditingController(text: 'Сохранённый черновик');
        addTearDown(draft.dispose);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2.5)),
              child: Scaffold(
                body: Column(
                  children: [
                    RouteStatusBanner(coordinator: router, syncOnline: true),
                    TextField(controller: draft, focusNode: focus),
                  ],
                ),
              ),
            ),
          ),
        );
        focus.requestFocus();
        await tester.pump();
        expect(find.textContaining('Нет связи'), findsOneWidget);
        expect(
          tester
              .widget<Semantics>(
                find
                    .ancestor(
                      of: find.textContaining('Нет связи'),
                      matching: find.byType(Semantics),
                    )
                    .first,
              )
              .properties
              .liveRegion,
          true,
        );
        expect(
          tester.getSize(find.widgetWithText(TextButton, 'Повторить')).height,
          greaterThanOrEqualTo(48),
        );
        available = true;
        await tester.runAsync(router.refresh);
        await tester.pump();
        expect(find.text('Сервис звонков временно недоступен'), findsOneWidget);
        expect(focus.hasFocus, true);
        expect(draft.text, 'Сохранённый черновик');
        control = true;
        await tester.runAsync(router.refresh);
        await tester.pump();
        expect(find.byType(TextButton), findsNothing);
        expect(focus.hasFocus, true);
        expect(draft.text, 'Сохранённый черновик');
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }
}
