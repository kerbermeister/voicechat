import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/chat_scale.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/link_cards.dart';
import 'package:voicechat_probe/resizable_chat_layout.dart';
import 'package:voicechat_probe/waveform_view.dart';
import 'conversation_list_test.dart' show ListClient;

void main() {
  testWidgets(
    'Waveform tap, drag and accessible seeking retain visible progress',
    (tester) async {
      var seek = 0.0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 216,
              child: WaveformView(
                levels: const [100, 400, 200],
                progress: .25,
                onSeek: (value) => seek = value,
              ),
            ),
          ),
        ),
      );
      final wave = find.byType(WaveformView);
      final rect = tester.getRect(wave);
      await tester.tapAt(rect.topLeft + const Offset(108, 20));
      await tester.pump();
      expect(seek, closeTo(.5, .01));
      final gesture = await tester.startGesture(
        rect.topLeft + const Offset(58, 20),
      );
      await gesture.moveTo(rect.topLeft + const Offset(158, 20));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(seek, closeTo(.75, .01));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Card rebuild retains decoded cover bytes and displays the whole image above compact text',
    (tester) async {
      final data = [
        {
          'url': 'https://www.youtube.com/watch?v=abcdefghijk',
          'title': 'Ролик',
          'description': 'Описание',
          'image': base64Encode(
            img.encodePng(img.Image(width: 160, height: 90)),
          ),
        },
      ];
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 280,
              child: LinkCards(text: data.first['url']!, previews: data),
            ),
          ),
        ),
      );
      await render();
      await tester.pump();
      final original =
          (tester.widget<Image>(find.byType(Image)).image as ResizeImage)
                  .imageProvider
              as MemoryImage;
      for (var i = 0; i < 30; i++) {
        await render();
        await tester.pump();
      }
      final current =
          (tester.widget<Image>(find.byType(Image)).image as ResizeImage)
                  .imageProvider
              as MemoryImage;
      expect(identical(original.bytes, current.bytes), true);
      expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.contain);
      expect(find.text('Смотреть видео'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Ролик')).dy,
        greaterThan(tester.getBottomLeft(find.byType(Image)).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Tall modal header close stays at top right and nested close preserves parent',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (parent) => AlertDialog(
                  title: const AppDialogTitle(
                    child: SizedBox(height: 150, child: Text('Группа')),
                  ),
                  content: TextButton(
                    onPressed: () => showAppDialog<void>(
                      context: parent,
                      builder: (_) => const AlertDialog(
                        title: AppDialogTitle(child: Text('Вложенное')),
                      ),
                    ),
                    child: const Text('Открыть'),
                  ),
                ),
              ),
              child: const Text('Настройки'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      final title = tester.getRect(find.byType(AppDialogTitle)),
          close = tester.getRect(find.byTooltip('Закрыть'));
      expect(close.top, title.top);
      expect(close.right, title.right);
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Закрыть').last);
      await tester.pumpAndSettle();
      expect(find.text('Группа'), findsOneWidget);
      expect(find.text('Вложенное'), findsNothing);
    },
  );
  testWidgets(
    'Clear scale route has no dimming or blur, live chat remains visible',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final scale = ChatScale();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  const Text('Переписка'),
                  TextButton(
                    onPressed: () => showAppDialog<void>(
                      context: context,
                      clearBackdrop: true,
                      builder: (_) => ChatScaleDialog(scale: scale),
                    ),
                    child: const Text('Масштаб'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Масштаб'));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      final barrier = tester.widget<ModalBarrier>(
        find.byType(ModalBarrier).last,
      );
      expect(barrier.color?.a ?? 0, 0);
      expect(find.text('Переписка'), findsOneWidget);
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      scale.dispose();
    },
  );
  testWidgets(
    'Resize grip is 24px, stable under mouse and clamps old widths to 16 percent',
    (tester) async {
      SharedPreferences.setMockInitialValues({'chat_sidebar_fraction': .07});
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResizableChatLayout(
              sidebar: (_) => const ColoredBox(
                key: ValueKey('sidebar'),
                color: Colors.blue,
              ),
              conversation: const Text('Чат'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final grip = find.bySemanticsLabel('Ширина списка людей и групп');
      expect(tester.getSize(grip).width, 24);
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 160);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(grip) + const Offset(9, 0));
      await tester.pump();
      final region = tester.widget<MouseRegion>(
        find.descendant(of: grip, matching: find.byType(MouseRegion)).first,
      );
      expect(region.cursor, SystemMouseCursors.resizeColumn);
      await mouse.down(tester.getCenter(grip) + const Offset(9, 0));
      await mouse.moveBy(const Offset(100, 0));
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('sidebar'))).width,
        greaterThan(230),
      );
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'Call preview uses voice or video icon and never leaks hidden/deleted events',
    () {
      final room = mx.Room(id: '!call:local', client: ListClient());
      for (final video in [false, true]) {
        room.lastEvent = mx.Event.fromJson({
          'event_id': '\$call',
          'type': mx.EventTypes.Message,
          'sender': '@peer:local',
          'content': {
            'msgtype': 'dev.voicechat.call_summary',
            'body': 'Звонок завершён',
            'video': video,
          },
        }, room);
        expect(
          lastCallIcon(room),
          video ? Icons.videocam_outlined : Icons.call_outlined,
        );
      }
      room.lastEvent = mx.Event.fromJson({
        'type': mx.EventTypes.Message,
        'sender': '@peer:local',
        'content': {'msgtype': mx.MessageTypes.Text, 'body': 'Текст'},
      }, room);
      expect(lastCallIcon(room), isNull);
    },
  );
}
