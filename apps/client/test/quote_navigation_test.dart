import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/message_metadata.dart';
import 'package:voicechat_probe/theme.dart';
import 'halo_capture_test.dart' show CaptureClient, CaptureTimeline;

class QuoteTimeline extends CaptureTimeline {
  QuoteTimeline(super.room);
  @override
  Future<mx.Event?> getEventById(String eventId) async =>
      events.where((e) => e.eventId == eventId).firstOrNull;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    for (final channel in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'com.llfbandit.record/messages',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
            if (call.method == 'create') {
              final id = (call.arguments as Map)['playerId'];
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(
                    MethodChannel('xyz.luan/audioplayers/events/$id'),
                    (_) async => null,
                  );
            }
            return null;
          });
    }
  });
  mx.Room roomFor(CaptureClient client, String id) {
    final room = mx.Room(id: id, client: client);
    room.states[mx.EventTypes.RoomMember] = {
      for (final user in [client.userID, '@friend:local'])
        user: mx.StrippedStateEvent(
          type: mx.EventTypes.RoomMember,
          stateKey: user,
          senderId: user,
          content: {'membership': 'join', 'displayname': user},
        ),
    };
    return room;
  }

  mx.Event event(mx.Room room, String id, {String? reply}) =>
      mx.Event.fromJson({
        'event_id': id,
        'sender': '@friend:local',
        'type': mx.EventTypes.Message,
        'origin_server_ts': 1792758000000,
        'content': {
          'msgtype': mx.MessageTypes.Text,
          'body': 'Сообщение $id',
          if (reply != null)
            'm.relates_to': {
              'm.in_reply_to': {'event_id': reply},
            },
        },
      }, room);
  Finder highlighted() => find.byWidgetPredicate(
    (w) => w is Container && w.foregroundDecoration != null,
  );

  testWidgets(
    'Quote can be highlighted again after clearing; history return and composer draft survive',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = CaptureClient();
      final room = roomFor(client, '!quote:local');
      final timeline = QuoteTimeline(room)
        ..events.addAll([
          event(room, 'source'),
          event(room, 'reply', reply: 'source'),
        ]);
      final actions = ChatActions(client);
      String? focus;
      var jumps = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return ChatPane(
                  key: const ValueKey('same-room'),
                  room: room,
                  timeline: timeline,
                  actions: actions,
                  header: const SizedBox(height: 50),
                  report: (_) {},
                  initialEventId: focus,
                  onJump: (id) async {
                    jumps++;
                    update(() => focus = id);
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.widgetWithText(TextField, 'Написать сообщение…');
      await tester.enterText(input, 'Сохранить черновик');
      final quote = find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label == 'Перейти к исходному сообщению',
      );
      await tester.tap(quote);
      await tester.pumpAndSettle();
      expect(jumps, 1);
      expect(highlighted(), findsOneWidget);
      expect(find.text('Вернуться к новым сообщениям'), findsOneWidget);
      final sourceMeta = find.byKey(const ValueKey('message-meta-source'));
      final before = tester.getRect(sourceMeta);
      await tester.tapAt(const Offset(12, 260));
      await tester.pumpAndSettle();
      expect(highlighted(), findsNothing);
      expect(tester.getRect(sourceMeta), before);
      await tester.tap(quote);
      await tester.pumpAndSettle();
      expect(highlighted(), findsOneWidget);
      expect(jumps, 1, reason: 'Same quote reuses the loaded history');
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Сохранить черновик',
      );
      await tester.tap(find.text('Вернуться к новым сообщениям'));
      await tester.pumpAndSettle();
      expect(focus, isNull);
      expect(highlighted(), findsNothing);
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Сохранить черновик',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      actions.dispose();
    },
  );

  testWidgets(
    'Scrolling toward newer messages clears an offscreen highlight but retains history return',
    (tester) async {
      final client = CaptureClient();
      final room = roomFor(client, '!scroll:local');
      final timeline = QuoteTimeline(room)
        ..events.addAll(List.generate(80, (i) => event(room, 'message$i')));
      final actions = ChatActions(client);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: Scaffold(
            body: ChatPane(
              room: room,
              timeline: timeline,
              actions: actions,
              header: const SizedBox(height: 40),
              report: (_) {},
              initialEventId: 'message40',
              onJump: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(highlighted(), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1300));
      await tester.pumpAndSettle();
      expect(highlighted(), findsNothing);
      expect(find.text('Вернуться к новым сообщениям'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      actions.dispose();
    },
  );

  testWidgets(
    'Adding reactions does not resize a message or move its neighbour',
    (tester) async {
      final client = CaptureClient();
      final room = roomFor(client, '!reaction:local');
      final timeline = QuoteTimeline(room)
        ..events.addAll([event(room, 'first'), event(room, 'second')]);
      final actions = ChatActions(client);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: Scaffold(
            body: ChatPane(
              room: room,
              timeline: timeline,
              actions: actions,
              header: const SizedBox(height: 40),
              report: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('first'));
      final second = find.byKey(const ValueKey('second'));
      final rect = tester.getRect(first), neighbour = tester.getRect(second);
      timeline.aggregatedEvents['first'] = {
        mx.RelationshipTypes.reaction: {
          mx.Event.fromJson({
            'event_id': 'reaction',
            'sender': '@friend:local',
            'type': 'm.reaction',
            'origin_server_ts': 1792758000000,
            'content': {
              'm.relates_to': {
                'rel_type': 'm.annotation',
                'event_id': 'first',
                'key': '👍',
              },
            },
          }, room),
        },
      };
      actions.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('👍 1'), findsOneWidget);
      expect(tester.getRect(first), rect);
      expect(tester.getRect(second), neighbour);
      expect(find.byType(MessageMetadata), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      actions.dispose();
    },
  );
}
