import 'test_fonts.dart';
// Opt-in visual capture of production widgets with local, fictional data.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/conversation_header.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/theme.dart';
import 'mobile_layout_test.dart' show LayoutClient, EmptyTimeline;

class CaptureClient extends LayoutClient {
  @override
  mx.PushRuleSet? globalPushRules;
  @override
  final rooms = <mx.Room>[];
}

class CaptureTimeline extends EmptyTimeline {
  CaptureTimeline(super.room);
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #setReadMarker) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Capture actual Halo widgets across surfaces', (tester) async {
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
    final font = FontLoader('Manrope');
    font.addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/fonts/Manrope-Variable.ttf').readAsBytesSync(),
        ),
      ),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            materialFontFile('MaterialIcons-Regular.otf').readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
    final client = CaptureClient();
    final room = mx.Room(
      id: '!halo:local',
      client: client,
      membership: mx.Membership.join,
    );
    client.rooms.add(room);
    client.directChats['@mama:local'] = [room.id];
    room.states[mx.EventTypes.RoomMember] = {
      for (final (id, name) in [
        ('@mama:local', 'Мама'),
        (client.userID, 'Антон'),
      ])
        id: mx.StrippedStateEvent(
          type: mx.EventTypes.RoomMember,
          stateKey: id,
          senderId: id,
          content: {'displayname': name, 'membership': 'join'},
        ),
    };
    client.presences['@mama:local'] = mx.CachedPresence(
      mx.PresenceType.online,
      0,
      null,
      true,
      '@mama:local',
    );
    final timeline = CaptureTimeline(room);
    final lines = [
      'В воскресенье собираемся у нас?',
      'Да, буду к пяти.',
      'Я привезу десерт.',
      'Отлично! Что-нибудь купить?',
      'Только чай, остальное есть.',
      'Договорились.',
      'Папа тоже будет к пяти.',
      'Уже написал ему.',
      'До встречи!',
    ];
    for (var i = 0; i < lines.length; i++) {
      timeline.events.insert(
        0,
        mx.Event.fromJson({
          'event_id': '\$halo$i',
          'sender': i.isOdd ? client.userID : '@mama:local',
          'type': mx.EventTypes.Message,
          'origin_server_ts': DateTime(
            2026,
            10,
            24,
            14,
            30 + i,
          ).millisecondsSinceEpoch,
          'content': {'body': lines[i], 'msgtype': mx.MessageTypes.Text},
        }, room),
      );
    }
    room.lastEvent = timeline.events.first;
    for (final name in [
      'Аня',
      'Папа',
      'Илья',
      'Мария',
      'Даша',
      'Иван',
      'Ольга',
    ]) {
      final id = '@${client.rooms.length}:local';
      final other = mx.Room(
        id: '!${client.rooms.length}:local',
        client: client,
        membership: mx.Membership.join,
      );
      client.directChats[id] = [other.id];
      other.states[mx.EventTypes.RoomMember] = {
        id: mx.StrippedStateEvent(
          type: mx.EventTypes.RoomMember,
          stateKey: id,
          senderId: id,
          content: {'displayname': name, 'membership': 'join'},
        ),
      };
      other.lastEvent = mx.Event.fromJson({
        'event_id': '\$${name}last',
        'sender': client.userID,
        'type': mx.EventTypes.Message,
        'origin_server_ts': DateTime(2026, 10, 24, 13).millisecondsSinceEpoch,
        'content': {
          'body': 'До встречи вечером',
          'msgtype': mx.MessageTypes.Text,
        },
      }, other);
      client.rooms.add(other);
    }
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final (name, size, list) in [
      ('desktop', const Size(1440, 900), true),
      ('android', const Size(390, 844), false),
      ('mobile-web', const Size(390, 756), false),
      ('people', const Size(390, 844), true),
    ]) {
      tester.view.physicalSize = size;
      final actions = ChatActions(client);
      final header = ConversationHeader(
        room: room,
        onClose: () {},
        onProfile: () {},
        onInfo: () {},
        onVoiceCall: () {},
        onVideoCall: () {},
      );
      final chat = ChatPane(
        room: room,
        timeline: timeline,
        actions: actions,
        report: (_) {},
        header: header,
        onVoiceCall: () {},
        onVideoCall: () {},
        onRoomInfo: () {},
      );
      final people = ConversationList(
        client: client,
        selected: room,
        groups: false,
        contactInvites: 2,
        onInvitations: () {},
        onSelect: (_) {},
        onTabChanged: (_) {},
        onNewPerson: () {},
        onNewGroup: () {},
        onSettings: () {},
        onSearch: () {},
        onProfile: () {},
        onChatMenu: (_, __) {},
        ownOnline: true,
      );
      const key = ValueKey('capture');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppPalette.halo.theme,
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: size.width > 1000
                  ? Row(
                      children: [
                        SizedBox(width: 300, child: people),
                        Expanded(child: chat),
                      ],
                    )
                  : list
                  ? people
                  : chat,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '../../docs/design/halo-typography/implementation-$name.png',
        );
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, skip: !const bool.fromEnvironment('HALO_CAPTURE'));
}
