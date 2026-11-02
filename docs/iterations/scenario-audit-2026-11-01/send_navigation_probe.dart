// UA-34: navigating away while a durable enqueue is pending. Fixture storage only.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_pane.dart';

import '../../../apps/client/test/message_actions_test.dart'
    show ForwardActions, ForwardRoom;
import '../../../apps/client/test/halo_capture_test.dart'
    show CaptureClient, CaptureTimeline;

class SlowEnqueue extends ForwardActions {
  SlowEnqueue(super.client);
  final committed = Completer<void>();
  final entered = Completer<void>();
  @override
  Future<String> enqueue(
    mx.Room room,
    Map<String, dynamic> content, {
    String type = mx.EventTypes.Message,
    mx.Event? reply,
    String? edit,
    bool preparing = false,
    int? ttlSeconds,
    int? readAfterSeconds,
    DateTime? scheduledFor,
  }) async {
    entered.complete();
    await committed.future;
    sent.add((room.id, content));
    return 'durably-queued';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'UA-34.C05 delayed successful enqueue after navigation must not report a send error',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'xyz.luan/audioplayers',
        'com.llfbandit.record/messages',
      ]) {
        messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          }
          return null;
        });
      }
      final client = CaptureClient();
      final room = ForwardRoom(client, '!qa:local');
      final actions = SlowEnqueue(client);
      final reports = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPane(
              key: const ValueKey('old-chat'),
              room: room,
              timeline: CaptureTimeline(room),
              actions: actions,
              header: const SizedBox(),
              report: reports.add,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'QA delayed message');
      await tester.tap(find.byTooltip('Отправить'));
      await tester.pump();
      expect(actions.entered.isCompleted, true);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Another chat'))),
      );
      actions.committed.complete();
      await tester.pump();
      await tester.pump();
      expect(actions.sent.single.$2['body'], 'QA delayed message');
      expect(
        reports,
        isEmpty,
        reason: 'The enqueue succeeded, so old widget disposal must not produce a false failure',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
