import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/delete_message_dialog.dart';
import 'package:voicechat_probe/people_picker.dart';
import 'package:voicechat_probe/theme.dart';

// Disposable UI fixture: no server, authentication, storage, microphone or camera.
class MotionDatabase implements mx.MatrixSdkDatabase {
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MotionClient extends mx.Client {
  MotionClient() : super('message-motion-fixture', database: MotionDatabase());
  @override
  String get userID => '@fixture:local';
  @override
  List<mx.Room> get rooms => [];
  @override
  Future<void> setTyping(
    String userId,
    String roomId,
    bool typing, {
    int? timeout,
  }) async {}
}

class MotionRoom extends mx.Room {
  MotionRoom(mx.Client client)
    : super(
        client: client,
        id: '!motion:local',
        membership: mx.Membership.join,
      );
  @override
  bool get encrypted => true;
  @override
  bool get canSendDefaultMessages => true;
}

class MotionTimeline implements mx.Timeline {
  @override
  final mx.Room room;
  MotionTimeline(this.room);
  @override
  final events = <mx.Event>[];
  @override
  final aggregatedEvents = <String, Map<String, Set<mx.Event>>>{};
  @override
  bool get canRequestHistory => false;
  @override
  bool get canRequestFuture => false;
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MotionActions extends ChatActions {
  final MotionTimeline timeline;
  MotionActions(super.client, this.timeline);
  var sequence = 0;
  final delivered = <String, String>{};
  @override
  String? deliveredEvent(String transaction) => delivered[transaction];
  @override
  Future<void> saveDraft(String roomId, String text) async {}
  @override
  Future<void> hideMessage(mx.Event event) async {
    timeline.events.remove(event);
    notifyListeners();
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
    final id = 'fixture-${++sequence}';
    final item = <String, dynamic>{
      'id': id,
      'room': room.id,
      'type': type,
      'content': content,
    };
    pending.add(item);
    notifyListeners();
    Timer(const Duration(milliseconds: 1600), () {
      final eventId = '\$$id';
      pending.remove(item);
      delivered[id] = eventId;
      timeline.events.insert(
        0,
        mx.Event.fromJson({
          'type': type,
          'event_id': eventId,
          'sender': client.userID,
          'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
          'content': content,
        }, room),
      );
      notifyListeners();
    });
    return id;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final client = MotionClient();
  final room = MotionRoom(client);
  room.states[mx.EventTypes.RoomMember] = {
    client.userID: mx.StrippedStateEvent(
      type: mx.EventTypes.RoomMember,
      stateKey: client.userID,
      senderId: client.userID,
      content: {'displayname': 'Тестовый профиль', 'membership': 'join'},
    ),
  };
  final timeline = MotionTimeline(room);
  final actions = MotionActions(client, timeline);
  runApp(
    MaterialApp(
      theme: AppPalette.halo.theme,
      home: Scaffold(
        body: Builder(
          builder: (context) => ChatPane(
            room: room,
            timeline: timeline,
            actions: actions,
            report: (message) => ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message))),
            header: Wrap(
              spacing: 12,
              children: [
                const Text('VoiceChat · только синтетические данные'),
                TextButton(
                  onPressed: () => showAppDialog<void>(
                    context: context,
                    builder: (_) => const DeleteMessageDialog(allowAll: true),
                  ),
                  child: const Text('Удаление'),
                ),
                TextButton(
                  onPressed: () => showAppDialog<void>(
                    context: context,
                    builder: (_) => PeoplePicker.group(
                      client: client,
                      allowedUsers: const {},
                    ),
                  ),
                  child: const Text('Новая группа'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
