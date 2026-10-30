import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/pending_message.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/personal_room.dart';
import 'halo_capture_test.dart' show CaptureClient, CaptureTimeline;
import 'message_actions_test.dart' show ForwardActions, ForwardRoom;

class DeliveryActions extends ForwardActions {
  DeliveryActions(super.client);
  var delivered = Completer<void>();
  int uploads = 0;
  bool acknowledged = false;
  int retries = 0;
  final retryGate = Completer<void>();
  @override
  Future<void> flush() async {
    retries++;
    await retryGate.future;
  }

  @override
  Future<String> attachment(
    mx.Room room,
    mx.MatrixFile file, {
    mx.Event? reply,
    List<int>? waveform,
    String caption = '',
    int? ttlSeconds,
    int? readAfterSeconds,
    DateTime? scheduledFor,
  }) async {
    uploads++;
    pending.add({
      'id': 'voice-transaction',
      'room': room.id,
      'type': mx.EventTypes.Message,
      'content': {
        'msgtype': mx.MessageTypes.Audio,
        'body': file.name,
        'dev.voicechat.waveform': waveform ?? <int>[],
      },
    });
    notifyListeners();
    return 'voice-transaction';
  }

  @override
  Future<void> waitForDelivery(String id) => delivered.future;
  @override
  String? deliveredEvent(String transaction) => acknowledged ? r'$voice' : null;
}

class PersonalRoom extends ForwardRoom {
  PersonalRoom(super.client, super.id);
  bool personal = true;
  mx.Event? last;
  @override
  mx.Event? get lastEvent => last;
  @override
  mx.StrippedStateEvent? getState(String type, [String stateKey = '']) =>
      type == mx.EventTypes.RoomCreate && personal
      ? mx.StrippedStateEvent(
          type: type,
          senderId: client.userID!,
          stateKey: '',
          content: {'type': personalRoomType},
        )
      : super.getState(type, stateKey);
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
  testWidgets('Personal room hides both call actions in desktop side panel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = CaptureClient();
    final room = PersonalRoom(client, '!notes:local');
    final actions = ForwardActions(client);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPane(
            room: room,
            timeline: CaptureTimeline(room),
            actions: actions,
            header: const SizedBox(height: 40),
            report: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Голосовой звонок'), findsNothing);
    expect(find.text('Видеозвонок'), findsNothing);
    expect(find.textContaining('Громкость сообщений'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    actions.dispose();
  });
  test(
    'Personal delivered notes are read without another participant receipt',
    () {
      final client = CaptureClient();
      final room = PersonalRoom(client, '!notes:local');
      final timeline = CaptureTimeline(room);
      for (final type in [
        mx.MessageTypes.Text,
        mx.MessageTypes.Audio,
        'dev.voicechat.file',
      ]) {
        final event = mx.Event.fromJson({
          'event_id': r'$note',
          'sender': client.userID,
          'type': mx.EventTypes.Message,
          'origin_server_ts': 0,
          'content': {'msgtype': type, 'body': 'Note'},
        }, room);
        timeline.events
          ..clear()
          ..add(event);
        room.last = event;
        expect(messageIsRead(event, timeline), true);
        expect(conversationDeliveryStatus(room)?.$2, 'Прочитано');
        room.personal = false;
        expect(messageIsRead(event, timeline), false);
        expect(conversationDeliveryStatus(room)?.$2, 'Отправлено');
        room.personal = true;
        for (final status in [mx.EventStatus.sending, mx.EventStatus.error]) {
          event.status = status;
          expect(messageIsRead(event, timeline), false);
          expect(
            conversationDeliveryStatus(room)?.$2,
            status == mx.EventStatus.sending ? 'Отправляется' : 'Не отправлено',
          );
        }
      }
    },
  );
  testWidgets(
    'Desktop Enter sends; platform modifier inserts newline and IME is preserved',
    (tester) async {
      final original = debugDefaultTargetPlatformOverride;
      addTearDown(() => debugDefaultTargetPlatformOverride = original);
      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = platform;
        final client = CaptureClient();
        final room = ForwardRoom(client, '!keyboard:local');
        final actions = ForwardActions(client);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatPane(
                room: room,
                timeline: CaptureTimeline(room),
                actions: actions,
                header: const SizedBox(height: 40),
                report: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.widgetWithText(TextField, 'Написать сообщение…');
        await tester.enterText(field, 'Первая строка');
        final modifier = platform == TargetPlatform.macOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Первая строка\n',
        );
        expect(actions.sent, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(actions.sent.length, 1);
        final controller = tester.widget<TextField>(field).controller!;
        controller.value = const TextEditingValue(
          text: 'IME',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(actions.sent.length, 1);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        actions.dispose();
      }
      debugDefaultTargetPlatformOverride = original;
    },
  );
  testWidgets(
    'Voice moves into history after local acceptance and waits there for acknowledgement',
    (tester) async {
      final client = CaptureClient();
      final room = ForwardRoom(client, '!voice:local');
      room.states[mx.EventTypes.RoomMember] = {
        client.userID: mx.StrippedStateEvent(
          type: mx.EventTypes.RoomMember,
          senderId: client.userID,
          stateKey: client.userID,
          content: {'membership': 'join', 'displayname': 'Тест'},
        ),
      };
      final actions = DeliveryActions(client);
      final timeline = CaptureTimeline(room);
      actions.composerDrafts[room.id] = ComposerDraft(
        files: [],
        photos: [],
        videoNote: false,
        voice: mx.MatrixAudioFile(
          bytes: Uint8List(48),
          name: 'voice.wav',
          mimeType: 'audio/wav',
          duration: 1000,
        ),
        wave: [30, 50],
      );
      final errors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPane(
              room: room,
              timeline: timeline,
              actions: actions,
              header: const SizedBox(height: 40),
              report: errors.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Отправить'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(actions.uploads, 1, reason: 'reported errors: $errors');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Голосовое ·'), findsNothing);
      expect(find.byType(PendingMessageContent), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sending:voice-transaction')),
        findsOneWidget,
      );
      expect(actions.acknowledged, false);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).readOnly,
        false,
      );
      actions.pending.single['error'] = 'offline';
      actions.notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PendingMessageContent), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await tester.tap(find.byTooltip('Ошибка отправки: подробности'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(find.text('Сообщение не отправлено'), findsOneWidget);
      expect(find.text('offline'), findsWidgets);
      expect(
        find.textContaining('Проверьте соединение и права'),
        findsOneWidget,
      );
      expect(find.text('Повторить сейчас'), findsOneWidget);
      await tester.tap(find.text('Повторить сейчас'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }

      expect(actions.retries, 1);
      expect(actions.retryGate.isCompleted, false);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).readOnly,
        false,
      );
      actions.retryGate.complete();
      actions.pending.single.remove('error');
      actions.notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
      expect(actions.uploads, 1);
      final event = mx.Event.fromJson({
        'event_id': r'$voice',
        'sender': client.userID,
        'type': mx.EventTypes.Message,
        'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
        'content': {
          'msgtype': mx.MessageTypes.Audio,
          'body': 'voice.wav',
          'url': 'mxc://local/audio',
          'info': {'duration': 1000, 'mimetype': 'audio/wav', 'size': 48},
        },
      }, room);
      timeline.events.add(event);
      actions.acknowledged = true;
      actions.pending.clear();
      actions.delivered.complete();
      actions.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('Голосовое ·'), findsNothing);
      expect(find.text('Голосовое сообщение'), findsOneWidget);
      await tester.tap(find.byTooltip('Действия с сообщением'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      await tester.tap(find.text('Информация'));
      await tester.pumpAndSettle();
      expect(find.textContaining('audio/wav'), findsOneWidget);
      expect(find.textContaining('48 байт'), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      expect(actions.uploads, 1, reason: 'reported errors: $errors');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      actions.dispose();
    },
  );
}
