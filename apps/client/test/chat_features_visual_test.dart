// Opt-in rendering of production widgets with fictional in-memory messages.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/theme.dart';
import 'halo_capture_test.dart' show CaptureClient, CaptureTimeline;
import 'message_actions_test.dart' show ForwardRoom, ForwardActions, addMembers;
import 'test_fonts.dart';

void main() {
  testWidgets('Render chat features at phone and desktop sizes', (
    tester,
  ) async {
    for (final channel in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'com.llfbandit.record/messages',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
            if (call.method == 'create') {
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockMethodCallHandler(
                    MethodChannel(
                      'xyz.luan/audioplayers/events/${call.arguments['playerId']}',
                    ),
                    (_) async => null,
                  );
            }
            return null;
          });
    }
    await loadAppFont();
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/Inter-Variable.ttf'))).load();
    final emoji = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (emoji.existsSync()) {
      await (FontLoader('Apple Color Emoji')..addFont(
            Future.value(ByteData.sublistView(emoji.readAsBytesSync())),
          ))
          .load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            materialFontFile('MaterialIcons-Regular.otf').readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
    for (final width in [390.0, 1000.0]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      final client = CaptureClient();
      final room = ForwardRoom(client, '!visual:local');
      addMembers(room);
      final timeline = CaptureTimeline(room);
      timeline.events.add(
        mx.Event.fromJson({
          'type': mx.EventTypes.Message,
          'event_id': r'$one',
          'sender': '@peer:local',
          'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
          'content': {
            'msgtype': mx.MessageTypes.Text,
            'body': 'Готово: ~~старый план~~ новый план ❤️',
          },
        }, room),
      );
      final actions = ForwardActions(client);
      actions.pending.addAll([
        {
          'id': 'file',
          'room': room.id,
          'type': mx.EventTypes.Message,
          'content': {
            'msgtype': 'dev.voicechat.file',
            'body': 'Документ.pdf',
            'mime': 'application/pdf',
            'caption': 'Вложения тоже сразу видны',
          },
        },
        {
          'id': 'text',
          'room': room.id,
          'type': mx.EventTypes.Message,
          'content': {
            'msgtype': mx.MessageTypes.Text,
            'body': 'Сообщение отправляется…',
          },
        },
        {
          'id': 'error',
          'room': room.id,
          'type': mx.EventTypes.Message,
          'error': 'Сервер запретил отправку в этот чат.',
          'failure': {
            'reason': 'Сервер запретил отправку в этот чат.',
            'recommendation':
                'Проверьте права на отправку и принятие приглашения.',
            'code': 'M_FORBIDDEN',
          },
          'content': {
            'msgtype': mx.MessageTypes.Text,
            'body': 'Сообщение с ошибкой',
          },
        },
      ]);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: AppPalette.halo.theme.copyWith(
              textTheme: AppPalette.halo.theme.textTheme.apply(
                fontFamilyFallback: ['Apple Color Emoji', 'Inter'],
              ),
            ),
            home: Scaffold(
              body: ChatPane(
                key: ValueKey(width),
                room: room,
                timeline: timeline,
                actions: actions,
                header: const ListTile(title: Text('Проверка чата')),
                report: (_) {},
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(tester.takeException(), isNull);
      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/private/tmp/voicechat-chat-$name-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('history');
      await tester.tap(find.byTooltip('Ошибка отправки: подробности'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('Код: M_FORBIDDEN'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('error');
      await tester.tap(find.text('Закрыть'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      await tester.tap(find.byTooltip('Действия с сообщением'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.byTooltip('Реакция ❤️'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('reactions');
      await tester.pumpWidget(const SizedBox());
      actions.dispose();
    }
    await tester.binding.setSurfaceSize(null);
  }, skip: !const bool.fromEnvironment('CHAT_FEATURES_CAPTURE'));
}
