import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:voicechat_probe/android_call_screen.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'call_window_test.dart' show CallRoom, WindowDatabase;

void main() {
  testWidgets(
    'Lock-screen call mode hides mounted chats and existing dialogs',
    (tester) async {
      final screen = AndroidCallScreen.instance;
      final nativeCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidCallScreen.channel, (call) async {
            nativeCalls.add(call.method);
            return null;
          });
      addTearDown(() {
        screen.active = false;
        screen.attach(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidCallScreen.channel, null);
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (_, child) =>
              AndroidCallScreenGate(child: child!, audioOutput: () async {}),
          home: const Scaffold(body: Text('Private chat')),
        ),
      );
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: Text('Private dialog')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private dialog'), findsOneWidget);
      screen.active = true;
      screen.attach(null);
      await tester.pump();
      expect(find.text('Private chat'), findsNothing);
      expect(find.text('Private dialog'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(nativeCalls, contains('ready'));
      final client = Client('locked-call', database: WindowDatabase());
      final calls = CallController(
        client,
        'http://localhost:8090',
        'ws://localhost:7880',
        (_) {},
      );
      calls.invitations['incoming'] = CallInvitation(
        CallRoom(client),
        'incoming',
        '@caller:local',
        DateTime.now(),
      );
      screen.attach(calls);
      await tester.pump();
      expect(find.text('Принять'), findsOneWidget);
      expect(find.text('Отклонить'), findsOneWidget);
      expect(find.text('Private chat'), findsNothing);
      expect(find.text('Private dialog'), findsNothing);
      calls.invitations.clear();
      calls.devices.changed();
      await tester.pump();
      await tester.tap(find.text('Закрыть'));
      await tester.pump();
      expect(nativeCalls, contains('hide'));
      expect(find.text('Private chat'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      screen.attach(null);
      await tester.runAsync(calls.close);
      await client.dispose();
    },
  );
}
