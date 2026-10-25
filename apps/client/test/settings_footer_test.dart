import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'contact_link_test.dart' show LinkClient, LinkContacts;
import 'contact_link_navigation_test.dart' show NavigationProbe;

void main() {
  testWidgets(
    'Mobile settings reserves at most 64px for Close and keeps an accessible touch target',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.halo.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: ProbeScreen(palette: AppPalette.halo, onPalette: (_) {}),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(ProbeScreen));
        final client = LinkClient(
          database: OutboxDatabase(),
          httpClient: MockClient((_) async => http.Response('{}', 500)),
        );
        state.setState(() {
          state.probe = NavigationProbe(client);
          state.linked = true;
          state.contacts = LinkContacts(client);
        });
        await tester.pumpAndSettle();
        unawaited(state.settings() as Future<void>);
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        final button = find.widgetWithText(TextButton, 'Закрыть');
        final scroll = find.descendant(
          of: dialog,
          matching: find.byType(SingleChildScrollView),
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
        expect(
          tester
                  .getRect(
                    find
                        .descendant(
                          of: find.byType(Dialog),
                          matching: find.byType(Material),
                        )
                        .first,
                  )
                  .bottom -
              tester.getRect(scroll).bottom,
          lessThanOrEqualTo(64),
        );
        expect(tester.getSize(scroll).height, greaterThan(150));
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
