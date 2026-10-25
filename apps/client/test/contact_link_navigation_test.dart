import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/contact_link_dialog.dart';
import 'package:voicechat_probe/main.dart';
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'contact_link_test.dart' show LinkClient, LinkContacts, receipt;

class NavigationProbe extends MatrixProbe {
  NavigationProbe(super.client);
  @override
  Future<void> close() async {}
}

void main() {
  testWidgets(
    'Invitation opens after login and device readiness, once per navigation, without accepting',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      Future<void> flush() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pump();
      }

      final url = 'https://chat.example/#/contact/${'a' * 43}';
      final requests = <String>[];
      final client = LinkClient(
        database: OutboxDatabase(),
        httpClient: MockClient((request) async {
          final action = jsonDecode(request.body)['action'] as String;
          requests.add(action);
          expect(action, 'inspect', reason: 'Opening must never give consent');
          return http.Response(jsonEncode(receipt()), 200);
        }),
      );
      Widget screen(int revision) => MaterialApp(
        home: ProbeScreen(
          palette: AppPalette.halo,
          onPalette: (_) {},
          invitation: url,
          invitationRevision: revision,
        ),
      );
      await tester.pumpWidget(screen(0));
      await flush();
      expect(find.byType(ContactLinkDialog), findsNothing);
      final dynamic state = tester.state(find.byType(ProbeScreen));
      state.setState(() {
        state.server.text = 'https://chat.example';
        state.probe = NavigationProbe(client);
        state.contacts = LinkContacts(client);
        state.linked = false;
      });
      await flush();
      expect(find.byType(ContactLinkDialog), findsNothing);
      state.setState(() {
        state.linked = true;
        state.restoringSession = true;
      });
      await flush();
      expect(find.byType(ContactLinkDialog), findsNothing);
      state.setState(() {
        state.restoringSession = false;
        state.busy = true;
      });
      await tester.pump();
      expect(find.byType(ContactLinkDialog), findsNothing);
      state.setState(() => state.busy = false);
      await flush();
      expect(find.byType(ContactLinkDialog), findsOneWidget);
      expect(requests, ['inspect']);
      expect(find.text('@owner:local'), findsOneWidget);

      // Rebuilds must not stack another modal or reopen a dismissed one.
      await tester.pumpWidget(screen(0));
      await flush();
      expect(find.byType(ContactLinkDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Закрыть'));
      await flush();
      await tester.pumpWidget(screen(0));
      await flush();
      expect(find.byType(ContactLinkDialog), findsNothing);
      expect(requests, ['inspect']);

      // The same URL arriving again is a new navigation, even without a new login.
      await tester.pumpWidget(screen(1));
      await flush();
      expect(find.byType(ContactLinkDialog), findsOneWidget);
      expect(requests, ['inspect', 'inspect']);
      await tester.tap(find.widgetWithText(TextButton, 'Закрыть'));
      await flush();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await flush();
    },
  );
}
