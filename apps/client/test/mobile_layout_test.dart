import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/theme.dart';
import 'conversation_list_test.dart' show ListClient;
import 'rich_media_test.dart' show RichClient;

class LayoutClient extends RichClient {
  @override
  Future<void> setTyping(
    String userId,
    String roomId,
    bool typing, {
    int? timeout,
  }) async {}
}

class EmptyTimeline implements mx.Timeline {
  @override
  final mx.Room room;
  EmptyTimeline(this.room);
  @override
  final events = <mx.Event>[];
  @override
  final aggregatedEvents = <String, Map<String, Set<mx.Event>>>{};
  @override
  bool get canRequestHistory => false;
  @override
  bool get canRequestFuture => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  testWidgets(
    'Mobile composer keeps text, recording and send visible; more actions preserve the draft',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      final room = mx.Room(id: '!layout:local', client: LayoutClient());
      final actions = ChatActions(room.client);
      for (final palette in [AppPalette.lavender, AppPalette.midnight]) {
        for (final width in [320.0, 390.0]) {
          tester.view.physicalSize = Size(width, 844);
          await tester.pumpWidget(
            MaterialApp(
              theme: palette.theme,
              home: Scaffold(
                body: ChatPane(
                  room: room,
                  timeline: EmptyTimeline(room),
                  actions: actions,
                  header: const SizedBox(height: 96),
                  report: (_) {},
                ),
              ),
            ),
          );
          await tester.pump();
          final field = find.widgetWithText(TextField, 'Написать сообщение…');
          expect(tester.getSize(field).width, greaterThanOrEqualTo(100));
          expect(
            find.byTooltip(
              'Голосовое · нажмите для видео, удерживайте для записи',
            ),
            findsOneWidget,
          );
          expect(find.byTooltip('Отправить изображение'), findsNothing);
          await tester.enterText(field, 'Черновик остаётся на месте');
          await tester.tap(find.byTooltip('Вложения и отправка'));
          await tester.pump();
          for (final label in [
            defaultTargetPlatform == TargetPlatform.iOS ||
                    defaultTargetPlatform == TargetPlatform.android
                ? 'Изображение из библиотеки'
                : 'Отправить изображение',
            'Прикрепить файл',
            'Прикрепить видео',
            'Временное сообщение',
            'Отложить отправку',
            'Запланированные сообщения',
          ]) {
            expect(find.text(label), findsOneWidget);
          }
          expect(find.byTooltip('Эмодзи'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Черновик остаётся на месте',
          );
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pump();
          expect(
            tester.getRect(find.byTooltip('Отправить')).bottom,
            lessThanOrEqualTo(564),
          );
          expect(tester.takeException(), isNull);
          tester.view.resetViewInsets();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
    },
  );
  testWidgets(
    'Conversation list fits a small phone with larger text and the search keyboard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetViewInsets);
      for (final scale in [1.0, 1.5]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.lavender.theme,
            builder: (_, child) => MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 640),
                textScaler: TextScaler.linear(scale),
                viewInsets: MediaQueryData.fromView(tester.view).viewInsets,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: ConversationList(
                client: ListClient(),
                groups: false,
                onTabChanged: (_) {},
                onSelect: (_) {},
                onNewPerson: () {},
                onNewGroup: () {},
                onSettings: () {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pump();
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
      }
    },
  );
}
