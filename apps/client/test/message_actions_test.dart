import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'video_note_test.dart' show NoteCamera;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/forward_message.dart';
import 'halo_capture_test.dart' show CaptureClient, CaptureTimeline;

class ForwardRoom extends mx.Room {
  ForwardRoom(mx.Client client, String id) : super(client: client, id: id);
  @override
  bool get encrypted => true;
  @override
  bool get canSendDefaultMessages => true;
}

class ForwardActions extends ChatActions {
  ForwardActions(super.client);
  final sent = <(String, Map<String, dynamic>)>[];
  @override
  Future<String> enqueue(
    mx.Room room,
    Map<String, dynamic> content, {
    String type = mx.EventTypes.Message,
    mx.Event? reply,
    String? edit,
    bool preparing = false,
    int? ttlSeconds,
    DateTime? scheduledFor,
  }) async {
    sent.add((room.id, content));
    return 'queued';
  }
}

class DelayedPolicyActions extends ForwardActions {
  DelayedPolicyActions(super.client);
  final policyReady = Completer<void>();
  @override
  Future<void> refreshPolicy() => policyReady.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('voicechat/save'),
          (_) async => Directory.systemTemp.path,
        );
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
  testWidgets(
    'Press begins recording before long-press timeout; swipe cancels without sending',
    (tester) async {
      final old = CameraPlatform.instance;
      final camera = NoteCamera();
      CameraPlatform.instance = camera;
      final client = CaptureClient();
      final room = ForwardRoom(client, '!record:local');
      final actions = DelayedPolicyActions(client);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPane(
              room: room,
              timeline: CaptureTimeline(room),
              actions: actions,
              header: const SizedBox(height: 50),
              report: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final press = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.videocam_outlined)),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(camera.starts, 1);
      expect(actions.policyReady.isCompleted, false);
      await press.moveBy(const Offset(-100, 0));
      await press.up();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      expect(camera.stops, 1);
      expect(actions.sent, isEmpty);
      actions.policyReady.complete();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      CameraPlatform.instance = old;
      await camera.initialized.close();
      camera.errors.add(CameraErrorEvent(1, 'disposed'));
      await camera.errors.close();
    },
  );
  testWidgets(
    'Right click matches dots; forward to same and other direct/group rooms',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = CaptureClient();
      final rooms = [
        for (var i = 0; i < 4; i++) ForwardRoom(client, '!room$i:local'),
      ];
      client.rooms.addAll(rooms);
      client.directChats['@peer:local'] = [rooms[0].id, rooms[1].id];
      for (var i = 0; i < rooms.length; i++) {
        rooms[i].states[mx.EventTypes.RoomName] = {
          '': mx.StrippedStateEvent(
            senderId: '@peer:local',
            type: mx.EventTypes.RoomName,
            stateKey: '',
            content: {'name': 'Chat $i'},
          ),
        };
        rooms[i].states[mx.EventTypes.RoomMember] = {
          '@peer:local': mx.StrippedStateEvent(
            senderId: '@peer:local',
            type: mx.EventTypes.RoomMember,
            stateKey: '@peer:local',
            content: {'membership': 'join', 'displayname': 'Alice'},
          ),
        };
      }
      final actions = ForwardActions(client);
      for (final source in [rooms[0], rooms[2]]) {
        final timeline = CaptureTimeline(source)
          ..events.add(
            mx.Event.fromJson({
              'type': mx.EventTypes.Message,
              'event_id': r'$message',
              'sender': '@peer:local',
              'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
              'content': {
                'msgtype': mx.MessageTypes.Text,
                'body': 'Forward me',
              },
            }, source),
          );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ChatPane(
                key: ValueKey(source.id),
                room: source,
                timeline: timeline,
                actions: actions,
                header: const SizedBox(height: 50),
                report: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Действия с сообщением'));
        await tester.pumpAndSettle();
        final dots = tester
            .widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>),
            )
            .map((w) => w.value)
            .toList();
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        for (final target in rooms) {
          final mouse = await tester.startGesture(
            tester.getCenter(find.text('Forward me')),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await mouse.up();
          await tester.pumpAndSettle();
          expect(
            tester
                .widgetList<PopupMenuItem<String>>(
                  find.byType(PopupMenuItem<String>),
                )
                .map((w) => w.value)
                .toList(),
            dots,
          );
          expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
          await tester.tap(find.text('Переслать'));
          await tester.pumpAndSettle();
          final index = rooms.indexOf(target);
          // Direct chats share the peer name; use picker row order for exact targets.
          await tester.tap(
            find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(ListTile),
                )
                .at(index),
          );
          await tester.pumpAndSettle();
          expect(actions.sent.last.$1, target.id);
          expect(actions.sent.last.$2[forwardedAuthorKey], 'Alice');
          expect(actions.sent.last.$2['body'], 'Forward me');
        }
      }
      expect(actions.sent, hasLength(8));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
