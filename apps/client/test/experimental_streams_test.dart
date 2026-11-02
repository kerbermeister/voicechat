import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/main.dart';
import 'package:voicechat_probe/stream_controller.dart';
import 'package:voicechat_probe/theme.dart';
import 'chat_actions_test.dart' show OutboxDatabase;
import 'contact_link_test.dart' show LinkClient, LinkContacts;
import 'contact_link_navigation_test.dart' show NavigationProbe;

void main() {
  testWidgets(
    'Streams are opt-in; disabling closes the controller and hides entry points',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
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
      expect(state.streamsEnabled, false);
      expect(state.streams, isNull);
      unawaited(state.settings() as Future<void>);
      await tester.pumpAndSettle();
      final experiments = find.text('Экспериментальные функции');
      await tester.ensureVisible(experiments);
      await tester.tap(experiments);
      await tester.pumpAndSettle();
      final toggle = find.widgetWithText(SwitchListTile, 'Стримы');
      await tester.ensureVisible(toggle);
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      await tester.tap(find.widgetWithText(TextButton, 'Закрыть'));
      await tester.pumpAndSettle();
      await state.setStreamsEnabled(true);
      await tester.pumpAndSettle();
      expect(state.streamsEnabled, true);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'experimentalStreamsEnabled',
        ),
        true,
      );
      final opened = state.streams as LiveStreamController;
      final closing = opened.close();
      await tester.pump();
      await closing;
      // A completed session is unnecessary: close itself must run before hiding UI.
      final controller = ClosingStream(client);
      state.setState(() {
        state.streamsEnabled = true;
        state.streams = controller;
      });
      await state.setStreamsEnabled(false);
      await tester.pumpAndSettle();
      expect(controller.closed, true);
      expect(state.streams, isNull);
      expect(state.streamsEnabled, false);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'experimentalStreamsEnabled',
        ),
        false,
      );
      expect(find.byTooltip('Стримы'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class ClosingStream extends LiveStreamController {
  bool closed = false;
  ClosingStream(LinkClient client)
    : super(
        client,
        'http://localhost:8090',
        'ws://localhost:7880',
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      );
  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}
