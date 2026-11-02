import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:voicechat_probe/call_controller.dart';
import 'package:voicechat_probe/call_window.dart';
import 'package:voicechat_probe/direct_call.dart';
import 'call_window_test.dart' show CallRoom, WindowCall, WindowDatabase;
import 'direct_call_protocol_test.dart' show ProtocolVoip, Session;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Ended session cannot close another room with the same call ID', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Event'),
      (_) async => null,
    );
    final client = Client('controller-room-scope', database: WindowDatabase());
    final calls = CallController(
      client,
      'http://localhost',
      'ws://localhost',
      (_) {},
    );
    final sessions = [
      for (final id in ['!old:fixture', '!new:fixture'])
        Session(
          CallOptions(
            callId: 'same-id',
            type: CallType.kVoice,
            dir: CallDirection.kOutgoing,
            localPartyId: 'local',
            voip: ProtocolVoip(),
            room: CallRoom(client, id: id),
            iceServers: [],
          ),
        ),
    ];
    final active = DirectCall(sessions.last, () {}, (_) {});
    try {
      for (final session in sessions) {
        await calls.registerListeners(session);
      }
      sessions.first.setCallState(CallState.kEnded);
      sessions.last.setCallState(CallState.kInviteSent);
      calls.active = active;
      await tester.runAsync(() => calls.handleCallEnded(sessions.first));
      await tester.pump();
      expect(sessions.last.callHasEnded, isFalse);
      expect(calls.active, same(active));
    } finally {
      await tester.runAsync(calls.close);
      await tester.runAsync(active.close);
      await tester.runAsync(client.dispose);
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Event'),
        null,
      );
    }
  });

  for (final replaced in [false, true]) {
    testWidgets(
      'Busy result belongs to its outgoing call; replaced=$replaced',
      (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'),
          (_) async => null,
        );
        final client = Client('busy-result', database: WindowDatabase());
        final calls = CallController(
          client,
          'http://localhost',
          'ws://localhost',
          (_) {},
        );
        final room = CallRoom(client);
        final session =
            Session(
                CallOptions(
                  callId: 'busy',
                  type: CallType.kVoice,
                  dir: CallDirection.kOutgoing,
                  localPartyId: 'local',
                  voip: ProtocolVoip(),
                  room: room,
                  iceServers: [],
                ),
              )
              ..hangupReason = CallErrorCode.userBusy
              ..setCallState(CallState.kEnded);
        final original = DirectCall(session, () {}, (_) {});
        final fresh = WindowCall(room);
        calls.active = replaced ? fresh : original;
        try {
          await tester.runAsync(() => calls.handleCallEnded(session));
          await tester.pumpWidget(
            MaterialApp(
              home: CallWindow(calls: calls, audioOutput: () async {}),
            ),
          );
          await tester.pump();
          if (replaced) {
            expect(calls.active, same(fresh));
            expect(calls.dialError, isNull);
            expect(
              find.text('Собеседник занят. Попробуйте позвонить ещё раз.'),
              findsNothing,
            );
          } else {
            expect(
              find.text('Собеседник занят. Попробуйте позвонить ещё раз.'),
              findsOneWidget,
            );
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(calls.close);
          await tester.runAsync(original.close);
          await tester.runAsync(client.dispose);
          messenger.setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Event'),
            null,
          );
        }
      },
    );
  }
}
