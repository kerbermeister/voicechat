import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/theme.dart';
import 'halo_capture_test.dart' show CaptureClient, CaptureTimeline;
import 'message_actions_test.dart' show ForwardRoom, ForwardActions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voicechat_probe/active_call_banner.dart';
import 'package:voicechat_probe/copy_feedback.dart';
import 'package:voicechat_probe/clipboard_file.dart';
import 'package:voicechat_probe/media_clipboard_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Clipboard commits exact bytes; truncated or oversized streams cancel',
    () async {
      final operations = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('voicechat/clipboard'),
        (call) async {
          operations.add(call);
          return call.method == 'begin' ? 'transfer' : null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('voicechat/clipboard'),
          null,
        ),
      );
      ClipboardFile file(int size, List<int> bytes) => ClipboardFile(
        name: 'photo.png',
        mime: 'image/png',
        size: size,
        read: () => Stream.value(Uint8List.fromList(bytes)),
      );
      await copyMediaFiles([
        file(3, [1, 2, 3]),
      ]);
      expect(operations.map((c) => c.method), ['begin', 'write', 'commit']);
      expect(operations[1].arguments['bytes'], [1, 2, 3]);
      for (final size in [2, 4]) {
        operations.clear();
        await expectLater(
          copyMediaFiles([
            file(size, [1, 2, 3]),
          ]),
          throwsStateError,
        );
        expect(operations.last.method, 'cancel');
        expect(operations.any((c) => c.method == 'commit'), false);
      }
    },
  );

  testWidgets(
    'Real message copy paints a contrasting border without changing bubble geometry in every theme',
    (tester) async {
      for (final channel in [
        'xyz.luan/audioplayers',
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'com.llfbandit.record/messages',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(channel), (call) async {
              if (call.method == 'create' &&
                  call.arguments is Map &&
                  call.arguments['playerId'] != null) {
                final id = call.arguments['playerId'];
                TestDefaultBinaryMessengerBinding
                    .instance
                    .defaultBinaryMessenger
                    .setMockMethodCallHandler(
                      MethodChannel('xyz.luan/audioplayers/events/$id'),
                      (_) async => null,
                    );
              }
              return null;
            });
      }
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add(call.arguments['text'] as String);
          }
          return null;
        },
      );
      final reports = <String>[];
      final client = CaptureClient();
      final room = ForwardRoom(client, '!copy:local');
      room.states[mx.EventTypes.RoomMember] = {
        for (final id in [client.userID, '@peer:local'])
          id: mx.StrippedStateEvent(
            type: mx.EventTypes.RoomMember,
            stateKey: id,
            senderId: id,
            content: {'membership': 'join', 'displayname': 'Пример'},
          ),
      };
      final timeline = CaptureTimeline(room);
      timeline.events.addAll([
        for (final own in [false, true])
          mx.Event.fromJson({
            'type': mx.EventTypes.Message,
            'event_id': own ? r'$own' : r'$peer',
            'sender': own ? client.userID : '@peer:local',
            'origin_server_ts': DateTime(
              2026,
              10,
              20,
              12,
            ).millisecondsSinceEpoch,
            'content': {
              'msgtype': mx.MessageTypes.Text,
              'body': own ? 'Мой пример' : 'Пример собеседника',
            },
          }, room),
      ]);
      Future<List<int>> pixels() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('paint-proof')),
        );
        final image = await tester.runAsync(
          () => boundary.toImage(pixelRatio: 1),
        );
        final bytes = await tester.runAsync(
          () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        image!.dispose();
        return bytes!.buffer.asUint8List().toList();
      }

      for (final palette in AppPalette.values) {
        for (final reduced in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: palette.theme,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  disableAnimations: reduced,
                  textScaler: const TextScaler.linear(2),
                ),
                child: child!,
              ),
              home: RepaintBoundary(
                key: const ValueKey('paint-proof'),
                child: Scaffold(
                  body: ChatPane(
                    room: room,
                    timeline: timeline,
                    actions: ForwardActions(client),
                    header: const SizedBox(height: 30),
                    report: reports.add,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final own in [false, true]) {
            final row = find.byKey(ValueKey(own ? r'$own' : r'$peer'));
            final feedback = find.descendant(
              of: row,
              matching: find.byType(CopyFeedback),
            );
            final original = tester.getRect(feedback);
            final button = tester.widget<IconButton>(
              find.descendant(
                of: row,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is IconButton && w.tooltip == 'Скопировать сообщение',
                ),
              ),
            );
            final before = await pixels();
            await tester.runAsync(() async {
              button.onPressed!();
              await Future<void>.delayed(Duration.zero);
            });
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 200));
            final after = await pixels();
            expect(
              after,
              isNot(equals(before)),
              reason: '${palette.name} own=$own reduced=$reduced',
            );
            expect(reports.last, 'Скопировано в буфер обмена');
            expect(copied.last, own ? 'Мой пример' : 'Пример собеседника');
            expect(tester.widget<CopyFeedback>(feedback).pulse, greaterThan(0));
            var changedEdge = 0;
            final boundaryRect = tester.getRect(
              find.byKey(const ValueKey('paint-proof')),
            );
            final width = boundaryRect.width.round();
            final y = (original.top - boundaryRect.top + 3).round();
            for (
              var x = (original.left - boundaryRect.left + 25).round();
              x < (original.right - boundaryRect.left - 25).round();
              x++
            ) {
              final offset = (y * width + x) * 4;
              if (before[offset] != after[offset] ||
                  before[offset + 1] != after[offset + 1] ||
                  before[offset + 2] != after[offset + 2]) {
                changedEdge++;
              }
            }
            expect(
              changedEdge,
              greaterThan(50),
              reason: 'Visible top border, not a button state',
            );
            expect(tester.getRect(feedback), original);
            expect(
              tester.widget<CopyFeedback>(feedback).color,
              own
                  ? palette.theme.extension<MessageColors>()!.foreground
                  : palette.theme.colorScheme.primary,
            );
            await tester.pumpAndSettle();
          }
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Copy pulse preserves geometry and repeats; reduced motion has no ticker',
    (tester) async {
      var pulse = 0;
      var reduced = false;
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: Center(
              child: CopyFeedback(
                pulse: pulse,
                child: const SizedBox(width: 240, height: 120),
              ),
            ),
          ),
        ),
      );
      await show();
      final original = tester.getRect(find.byType(CopyFeedback));
      for (var i = 0; i < 2; i++) {
        pulse++;
        await show();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.getRect(find.byType(CopyFeedback)), original);
        await tester.pumpAndSettle();
      }
      reduced = true;
      await show();
      pulse++;
      await show();
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Active call banner is actionable and static with reduced motion on a small screen',
    (tester) async {
      var taps = 0;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              disableAnimations: true,
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: ActiveCallBanner(
                label: 'Идёт звонок · Вернуться к звонку',
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
