import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/conversation_header.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/theme.dart';
import 'conversation_list_test.dart' show ListClient;
import 'mobile_layout_test.dart' show LayoutClient, EmptyTimeline;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final channel in [
    'xyz.luan/audioplayers',
    'xyz.luan/audioplayers.global',
    'com.llfbandit.record/messages',
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
  }
  test(
    'Latest-message receipts never treat sending, errors or unrelated receipts as read',
    () {
      final client = ListClient();
      final room = mx.Room(id: '!receipt:local', client: client);
      void setEvent(mx.EventStatus status, {String? sender}) {
        room.lastEvent = null;
        room.lastEvent = mx.Event(
          eventId: 'last',
          senderId: sender ?? client.userID,
          room: room,
          type: mx.EventTypes.Message,
          status: status,
          originServerTs: DateTime.now(),
          content: {'body': 'Привет', 'msgtype': mx.MessageTypes.Text},
        );
      }

      setEvent(mx.EventStatus.synced);
      expect(conversationDeliveryStatus(room)?.$1, Icons.done);
      room.receiptState.global.otherUsers['@peer:local'] =
          mx.LatestReceiptStateData('unrelated', 999999);
      expect(conversationDeliveryStatus(room)?.$1, Icons.done);
      room.receiptState.global.otherUsers['@peer:local'] =
          mx.LatestReceiptStateData('last', 0);
      expect(conversationDeliveryStatus(room)?.$1, Icons.done_all);
      setEvent(mx.EventStatus.sending);
      expect(conversationDeliveryStatus(room)?.$2, 'Отправляется');
      setEvent(mx.EventStatus.error);
      expect(conversationDeliveryStatus(room)?.$2, 'Не отправлено');
      setEvent(mx.EventStatus.synced, sender: '@peer:local');
      expect(conversationDeliveryStatus(room), isNull);
    },
  );
  testWidgets(
    'Invitations appear below tabs only when present; footer remains accessible',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var opened = false;
      for (final (incoming, outgoing) in [(0, 0), (2, 0), (0, 2), (0, 0)]) {
        final count = incoming + outgoing;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.halo.theme,
            home: Scaffold(
              body: ConversationList(
                client: ListClient(),
                groups: false,
                contactInvites: incoming,
                outgoingInvites: outgoing,
                onInvitations: () => opened = true,
                onTabChanged: (_) {},
                onSelect: (_) {},
                onNewPerson: () {},
                onNewGroup: () {},
                onSettings: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('pending-invitations')),
          count == 0 ? findsNothing : findsOneWidget,
        );
        if (count > 0) {
          expect(
            tester.getTopLeft(find.text('Приглашения')).dy,
            greaterThan(
              tester.getBottomLeft(find.byType(SegmentedButton<bool>)).dy,
            ),
          );
          await tester.tap(find.text('Приглашения'));
          expect(opened, isTrue);
        }
        expect(
          tester.getBottomLeft(find.text('Найти человека')).dy,
          lessThan(568),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets('Actual header keeps both call actions at 320px and large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = LayoutClient();
    final room = mx.Room(id: '!header:local', client: client);
    var voice = 0, video = 0;
    for (final size in [
      const Size(320, 568),
      const Size(640, 320),
      const Size(1440, 900),
    ]) {
      tester.view.physicalSize = size;
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
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: ConversationHeader(
                  room: room,
                  onClose: () {},
                  onProfile: () {},
                  onVoiceCall: () => voice++,
                  onVideoCall: () => video++,
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Голосовой звонок'));
        await tester.tap(find.byTooltip('Видеозвонок'));
        expect(tester.takeException(), isNull);
      }
    }
    expect(voice, 6);
    expect(video, 6);
  });
  testWidgets(
    'Sidebar collapse and resize preserve draft; callbacks and search stay connected',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1306, 820);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final room = mx.Room(id: '!sidebar:local', client: LayoutClient());
      final actions = ChatActions(room.client);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: Scaffold(
            body: ChatPane(
              room: room,
              timeline: EmptyTimeline(room),
              actions: actions,
              report: (_) {},
              header: ConversationHeader(
                room: room,
                onClose: () {},
                onProfile: () {},
              ),
              onVoiceCall: () => calls++,
              onVideoCall: () => calls++,
              onRoomInfo: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, 'Написать сообщение…');
      await tester.enterText(field, 'Не потерять черновик');
      await tester.tap(find.text('Голосовой звонок'));
      await tester.tap(find.text('Видеозвонок'));
      expect(calls, 2);
      await tester.tap(find.text('Поиск в переписке'));
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Поиск по загруженной истории'),
            )
            .focusNode!
            .hasFocus,
        isTrue,
      );
      final beforeWidth = tester.getSize(find.byType(ConversationHeader)).width;
      await tester.tap(find.byTooltip('Свернуть панель чата'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final duringWidth = tester.getSize(find.byType(ConversationHeader)).width;
      expect(duringWidth, greaterThan(beforeWidth));
      expect(duringWidth, lessThan(beforeWidth + 264));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.key == const ValueKey('chat-details-panel'),
        ),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Не потерять черновик',
      );
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-details-toggle')), findsNothing);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Не потерять черновик',
      );
      tester.view.physicalSize = const Size(1306, 820);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Открыть панель чата'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is SizedBox && w.key == const ValueKey('chat-details-panel'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
