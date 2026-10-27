import 'dart:io';
import 'package:voicechat_probe/message_motion.dart';
import 'package:image/image.dart' as img;
import 'package:voicechat_probe/file_drop.dart';
import 'package:voicechat_probe/picked_file.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
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
  Future<void> saveDraft(String roomId, String text) async {
    drafts[roomId] = text;
  }

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

class MotionActions extends ChatActions {
  MotionActions(super.client, {super.onDeleted});
  final delivered = <String, String>{};
  bool failDeletion = false;
  @override
  String? deliveredEvent(String transaction) => delivered[transaction];
  @override
  Future<void> saveDraft(String roomId, String text) async {}
  @override
  Future<void> hideMessage(mx.Event event) async {
    if (failDeletion) throw StateError('offline');
  }

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
    const id = 'motion-transaction';
    pending.add({'id': id, 'room': room.id, 'type': type, 'content': content});
    notifyListeners();
    return id;
  }

  void confirm(CaptureTimeline timeline) {
    final item = pending.removeLast();
    delivered[item['id'] as String] = r'$delivered';
    timeline.events.insert(
      0,
      mx.Event.fromJson({
        'type': mx.EventTypes.Message,
        'event_id': r'$delivered',
        'sender': client.userID,
        'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
        'content': item['content'],
      }, timeline.room),
    );
    notifyListeners();
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
    'Text keeps a real pending state, then flies to one delivered message and cleans overlays',
    (tester) async {
      final client = CaptureClient();
      final room = ForwardRoom(client, '!motion:local');
      room.states[mx.EventTypes.RoomMember] = {
        client.userID: mx.StrippedStateEvent(
          type: mx.EventTypes.RoomMember,
          stateKey: client.userID,
          senderId: client.userID,
          content: {'displayname': 'Me', 'membership': 'join'},
        ),
      };
      final timeline = CaptureTimeline(room);
      final actions = MotionActions(client);
      await tester.pumpWidget(
        MaterialApp(
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
      await tester.enterText(find.byType(TextField).last, 'Motion message');
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Отправить'));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pump();
      expect(actions.pending.length, 1);
      expect(find.text('Motion message'), findsOneWidget);
      actions.confirm(timeline);
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tester.pump();
      expect(actions.pending, isEmpty);
      expect(find.text('Motion message'), findsOneWidget);
      expect(find.byType(RawImage), findsWidgets);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Failed deletion keeps the message and produces no success sound',
    (tester) async {
      final client = CaptureClient();
      final room = ForwardRoom(client, '!delete:local');
      room.states[mx.EventTypes.RoomMember] = {
        '@peer:local': mx.StrippedStateEvent(
          type: mx.EventTypes.RoomMember,
          stateKey: '@peer:local',
          senderId: '@peer:local',
          content: {'displayname': 'Peer', 'membership': 'join'},
        ),
      };
      final timeline = CaptureTimeline(room)
        ..events.add(
          mx.Event.fromJson({
            'type': mx.EventTypes.Message,
            'event_id': r'$delete',
            'sender': '@peer:local',
            'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
            'content': {
              'msgtype': mx.MessageTypes.Text,
              'body': 'Keep on failure',
            },
          }, room),
        );
      var sounds = 0;
      final reports = <String>[];
      final actions = MotionActions(client, onDeleted: () => sounds++)
        ..failDeletion = true;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: ChatPane(
              room: room,
              timeline: timeline,
              actions: actions,
              header: const SizedBox(height: 40),
              report: reports.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Действия с сообщением'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить у меня'));
      await tester.pumpAndSettle();
      expect(sounds, 0);
      expect(reports, isNotEmpty);
      expect(find.text('Keep on failure'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Phone photo menu distinguishes library and camera; cancellation preserves the draft',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final choices = <Map<dynamic, dynamic>>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('voicechat/images'),
        (call) async {
          if (call.method == 'choose') choices.add(call.arguments as Map);
          return null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('voicechat/images'),
          null,
        ),
      );
      final client = CaptureClient();
      final room = ForwardRoom(client, '!photo:local');
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
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'Keep this draft');
      for (final label in ['Сделать фото', 'Изображение из библиотеки']) {
        await tester.tap(find.byTooltip('Вложения и отправка'));
        await tester.pumpAndSettle();
        expect(find.text('Сделать фото'), findsOneWidget);
        expect(find.text('Изображение из библиотеки'), findsOneWidget);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(choices.last['camera'], label == 'Сделать фото');
        if (label == 'Сделать фото') expect(choices.last['max_count'], 1);
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Keep this draft',
        );
        expect(actions.sent, isEmpty);
      }
      // The system chooser opens without waiting for a policy network request.
      expect(actions.policyReady.isCompleted, false);
      actions.policyReady.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      await actions.close();
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );
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
  testWidgets('Holding microphone never opens camera or switches to video', (
    tester,
  ) async {
    final previous = CameraPlatform.instance;
    final camera = NoteCamera();
    CameraPlatform.instance = camera;
    addTearDown(() => CameraPlatform.instance = previous);
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (call) async {
            calls.add(call.method);
            if (call.method == 'hasPermission') return true;
            if (call.method == 'startStream') {
              expect(call.arguments['encoder'], 'pcm16bits');
              expect(call.arguments['autoGain'], true);
              throw PlatformException(code: 'test-stream-unavailable');
            }
            return null;
          },
        );
    final client = CaptureClient();
    final room = ForwardRoom(client, '!audio-only:local');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatPane(
            room: room,
            timeline: CaptureTimeline(room),
            actions: ForwardActions(client),
            header: const SizedBox(height: 50),
            report: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final press = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic_none)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await press.up();
    await tester.pumpAndSettle();
    expect(calls, containsAllInOrder(['hasPermission', 'startStream']));
    expect(camera.starts, 0);
    expect(camera.creations, 0);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
    expect(find.byIcon(Icons.videocam_outlined), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await camera.initialized.close();
    await camera.errors.close();
  });
  testWidgets(
    'Tap switches recording mode; hold starts video and swipe cancels',
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
      expect(find.byIcon(Icons.videocam_outlined), findsNothing);
      await tester.tapAt(tester.getCenter(find.byIcon(Icons.mic_none)));
      await tester.pump();
      expect(camera.starts, 0);
      await tester.tapAt(
        tester.getCenter(find.byIcon(Icons.videocam_outlined)),
      );
      await tester.pump();
      expect(find.byIcon(Icons.mic_none), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.byIcon(Icons.mic_none)));
      await tester.pump();
      final press = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.videocam_outlined)),
      );
      await tester.pump(const Duration(milliseconds: 600));
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
      final opened = <String>[];
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
                onForward: (target) async {
                  opened.add(target.id);
                },
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
        await tester.longPress(find.text('Forward me'));
        await tester.pumpAndSettle();
        expect(find.text('Ответить'), findsOneWidget);
        expect(
          tester
              .widgetList<MessageMenuHighlight>(
                find.byType(MessageMenuHighlight),
              )
              .where((widget) => widget.selected)
              .length,
          1,
        );
        expect(find.byIcon(Icons.reply), findsOneWidget);
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
          if (source != target) expect(opened.last, target.id);
          expect(actions.sent.last.$1, target.id);
          expect(actions.sent.last.$2[forwardedAuthorKey], 'Alice');
          expect(actions.sent.last.$2['body'], 'Forward me');
        }
      }
      expect(actions.sent, hasLength(8));
      expect(opened, hasLength(6));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
