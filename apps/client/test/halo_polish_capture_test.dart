import 'test_fonts.dart';
// Opt-in snapshots of real widgets with fictional local fixtures; no account login.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/chat_actions.dart';
import 'package:voicechat_probe/chat_pane.dart';
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/conversation_header.dart';
import 'package:voicechat_probe/profile_dialog.dart';
import 'package:voicechat_probe/people_picker.dart';
import 'package:voicechat_probe/scheduled_view.dart';
import 'scheduled_queue_test.dart' show QueueService;
import 'quote_navigation_test.dart' show QuoteTimeline;
import 'package:voicechat_probe/theme.dart';
import 'halo_capture_test.dart' show CaptureClient;
import 'halo_polish_test.dart' show ProfileContacts;

class PolishCaptureClient extends CaptureClient {
  @override
  Future<mx.Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration timeout = const Duration(seconds: 30),
    Duration maxCacheAge = const Duration(days: 1),
  }) async => mx.Profile(userId: userId, displayName: 'Александра Соколова');
}

void main() {
  testWidgets('Capture group colors, search spacing and profile backdrop', (
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
    for (final (name, file) in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      final font = FontLoader(name)
        ..addFont(
          Future.value(
            ByteData.sublistView(materialFontFile(file).readAsBytesSync()),
          ),
        );
      await font.load();
    }
    if (File('/System/Library/Fonts/Menlo.ttc').existsSync()) {
      final mono = FontLoader('monospace')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('/System/Library/Fonts/Menlo.ttc').readAsBytesSync(),
            ),
          ),
        );
      await mono.load();
    }
    final emojiFile = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (emojiFile.existsSync()) {
      final emoji = FontLoader('Emoji')
        ..addFont(
          Future.value(ByteData.sublistView(emojiFile.readAsBytesSync())),
        );
      await emoji.load();
    }
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final client = PolishCaptureClient();
    final members = {
      client.userID: 'Вы',
      '@anna:local': 'Анна',
      '@sasha:local': 'Александра',
      '@ilya:local': 'Илья',
    };
    final room = mx.Room(
      id: '!family:local',
      client: client,
      membership: mx.Membership.join,
    );
    room.states[mx.EventTypes.RoomName] = {
      '': mx.StrippedStateEvent(
        type: mx.EventTypes.RoomName,
        stateKey: '',
        senderId: client.userID,
        content: {'name': 'Семья'},
      ),
    };
    room.states[mx.EventTypes.RoomMember] = {
      for (final entry in members.entries)
        entry.key: mx.StrippedStateEvent(
          type: mx.EventTypes.RoomMember,
          stateKey: entry.key,
          senderId: entry.key,
          content: {'displayname': entry.value, 'membership': 'join'},
        ),
    };
    room.summary.mJoinedMemberCount = members.length;
    room.summary.mInvitedMemberCount = 0;
    client.rooms.add(room);
    for (final entry in members.entries.where(
      (entry) => entry.key != client.userID,
    )) {
      final direct = mx.Room(id: '!dm-${entry.value}:local', client: client);
      direct.states[mx.EventTypes.RoomMember] =
          room.states[mx.EventTypes.RoomMember]!;
      client.rooms.add(direct);
      client.directChats[entry.key] = [direct.id];
    }
    final timeline = QuoteTimeline(room);
    final messages = [
      'В субботу собираемся у нас?',
      'Да, я буду к пяти.',
      'Привезу десерт и чай.',
      'Отлично, до встречи!',
      'Возьму настольную игру.',
      'Всех ждём!',
    ];
    for (var i = 0; i < messages.length; i++) {
      timeline.events.insert(
        0,
        mx.Event.fromJson({
          'event_id': '\$polish$i',
          'sender': members.keys.elementAt(i % members.length),
          'type': mx.EventTypes.Message,
          'origin_server_ts': DateTime(
            2026,
            10,
            24,
            17,
            i,
          ).millisecondsSinceEpoch,
          'content': {
            'body': messages[i],
            'msgtype': mx.MessageTypes.Text,
            if (i == 4)
              'm.relates_to': {
                'm.in_reply_to': {'event_id': r'$polish2'},
              },
          },
        }, room),
      );
    }
    timeline.aggregatedEvents[r'$polish4'] = {
      mx.RelationshipTypes.reaction: {
        mx.Event.fromJson({
          'event_id': 'reaction',
          'sender': '@anna:local',
          'type': 'm.reaction',
          'origin_server_ts': 1792758000000,
          'content': {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': r'$polish4',
              'key': '👍',
            },
          },
        }, room),
      },
    };
    room.lastEvent = timeline.events.first;
    final actions = ChatActions(client);
    final contacts = ProfileContacts(client)..available = true;
    const captureKey = ValueKey('polish-capture');
    for (final (surface, size) in [
      ('desktop', const Size(1366, 768)),
      ('mobile', const Size(390, 844)),
    ]) {
      tester.view.physicalSize = size;
      for (final listOnly in [false, true]) {
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppPalette.halo.theme.copyWith(
                textTheme: AppPalette.halo.theme.textTheme.apply(
                  fontFamilyFallback: ['Emoji'],
                ),
              ),
              locale: const Locale('ru'),
              supportedLocales: const [Locale('ru')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(alwaysUse24HourFormat: true),
                child: child!,
              ),
              home: Builder(
                builder: (context) {
                  void profile() => showAppDialog<void>(
                    context: context,
                    builder: (_) => ProfileDialog(
                      client: client,
                      contacts: contacts,
                      userId: '@sasha:local',
                    ),
                  );
                  final list = ConversationList(
                    client: client,
                    groups: true,
                    onTabChanged: (_) {},
                    onSelect: (_) {},
                    onNewPerson: () {},
                    onNewGroup: () {},
                    onSettings: () {},
                    selected: room,
                  );
                  final chat = ChatPane(
                    room: room,
                    timeline: timeline,
                    actions: actions,
                    report: (_) {},
                    header: ConversationHeader(
                      room: room,
                      onClose: () {},
                      onProfile: profile,
                      onInfo: profile,
                      onVoiceCall: () {},
                      onVideoCall: () {},
                    ),
                  );
                  return Scaffold(
                    body: listOnly
                        ? list
                        : size.width > 1000
                        ? Row(
                            children: [
                              SizedBox(width: 300, child: list),
                              VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: AppPalette
                                    .halo
                                    .theme
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: .5),
                              ),
                              Expanded(child: chat),
                            ],
                          )
                        : chat,
                  );
                },
              ),
            ),
          ),
        );
        Future<void> capture(String name) async {
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(captureKey))
                .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('../../docs/design/halo-polish/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('$surface-${listOnly ? 'groups' : 'chat'}');
        if (!listOnly) {
          await tester.tap(
            find.descendant(
              of: find.byType(ConversationHeader),
              matching: find.text('Семья'),
            ),
          );
          await capture('$surface-profile');
          await tester.tap(find.byTooltip('Закрыть'));
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(Scaffold).first);
          showAppDialog<GroupDraft>(
            context: context,
            builder: (_) => PeoplePicker.group(
              client: client,
              allowedUsers: members.keys
                  .where((id) => id != client.userID)
                  .toSet(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextFormField),
            'Семейные встречи',
          );
          await tester.tap(find.byType(CheckboxListTile).first);
          await capture('$surface-new-group');
          await tester.tap(find.byTooltip('Закрыть'));
          await tester.pumpAndSettle();
          chooseScheduledTime(
            context,
            86400,
            initial: DateTime.now().add(const Duration(hours: 1)),
          );
          await capture('$surface-planner');
          await tester.tap(find.byTooltip('Закрыть'));
          await tester.pumpAndSettle();
          showAppDialog<void>(
            context: context,
            builder: (_) =>
                ScheduledView(service: QueueService(), roomId: room.id),
          );
          await capture('$surface-scheduled');
          await tester.tap(find.byTooltip('Закрыть'));
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    contacts.dispose();
  }, skip: !const bool.fromEnvironment('HALO_POLISH_CAPTURE'));
}
