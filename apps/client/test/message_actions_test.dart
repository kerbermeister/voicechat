import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:voicechat_probe/file_drop.dart';
import 'package:voicechat_probe/picked_file.dart';
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

class DropActions extends ForwardActions {
  DropActions(super.client);
  @override
  Future<void> saveDraft(String roomId, String text) async {
    drafts[roomId] = text;
  }

  int albums = 0, files = 0;
  String? albumCaption;
  bool failFile = true;
  @override
  Future<void> album(
    mx.Room room,
    List<mx.MatrixImageFile> photos,
    String caption, {
    mx.Event? reply,
    int? ttlSeconds,
    DateTime? scheduledFor,
  }) async {
    albums++;
    albumCaption = caption;
  }

  @override
  Future<void> file(
    mx.Room room,
    PickedFile source,
    String caption, {
    mx.Event? reply,
    bool videoNote = false,
    int? duration,
    void Function(double)? progress,
    bool Function()? cancelled,
    int? ttlSeconds,
    DateTime? scheduledFor,
  }) async {
    if (failFile) throw StateError('test upload failure');
    files++;
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
    'Mixed drop keeps the draft and does not resend photos after a file retry',
    (tester) async {
      final client = CaptureClient();
      final room = ForwardRoom(client, '!drop:local');
      final actions = DropActions(client);
      final errors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatPane(
              room: room,
              timeline: CaptureTimeline(room),
              actions: actions,
              header: const SizedBox(height: 50),
              report: errors.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'Caption stays here');
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 20, height: 12)),
      );
      var releases = 0;
      PickedFile file(String name, String mime, Uint8List bytes) => PickedFile(
        name: name,
        mime: mime,
        size: bytes.length,
        read: (start, end) async => bytes.sublist(start, end),
        release: () async {
          releases++;
        },
      );
      tester.widget<FileDrop>(find.byType(FileDrop)).onDrop([
        file('photo.png', 'image/png', png),
        file('report.pdf', 'application/pdf', Uint8List(4)),
      ]);
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester.widget<FileDrop>(find.byType(FileDrop)).enabled) break;
      }
      await tester.pumpAndSettle();
      expect(errors, isEmpty);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.textContaining('Прикреплено фото: 1'), findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Caption stays here',
      );
      await tester.tap(find.byTooltip('Отправить'));
      await tester.pumpAndSettle();
      expect(actions.albums, 1);
      expect(actions.albumCaption, 'Caption stays here');
      expect(errors, hasLength(1));
      expect(find.text('report.pdf'), findsOneWidget);
      actions.failFile = false;
      await tester.tap(find.byTooltip('Отправить'));
      await tester.pumpAndSettle();
      expect(actions.albums, 1);
      expect(actions.files, 1);
      expect(releases, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
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
          if (!target.isDirectChat) {
            await tester.tap(find.text('Группы'));
            await tester.pumpAndSettle();
          }
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byKey(ValueKey(target.id)),
            ),
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
