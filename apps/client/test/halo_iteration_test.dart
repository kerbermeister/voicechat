import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/app_motion.dart';
import 'package:voicechat_probe/device_added.dart';
import 'package:voicechat_probe/message_metadata.dart';
import 'package:voicechat_probe/conversation_list.dart'
    show conversationDeliveryStatus, PersonAvatar;
import 'package:voicechat_probe/matrix_probe.dart';
import 'package:voicechat_probe/people_picker.dart';
import 'package:voicechat_probe/theme.dart';
import 'conversation_list_test.dart' show ListClient;

class MetadataClient extends ListClient {
  @override
  String get deviceID => 'phone / 1';
  @override
  final accountData = <String, mx.BasicEvent>{};
  int writes = 0;
  bool fail = false;
  Map<Symbol, dynamic>? creation;
  @override
  Future<void> setAccountData(
    String userId,
    String type,
    dynamic content,
  ) async {
    writes++;
    if (fail) throw StateError('offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #createRoom) {
      creation = invocation.namedArguments;
      return Future<String>.value('!new:local');
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'Device added date is recorded once; missing, invalid and failed metadata remain unknown',
    () async {
      final client = MetadataClient();
      expect(deviceAddedAt(client, client.deviceID), isNull);
      final now = DateTime.now();
      await recordDeviceAdded(client, now);
      expect(
        deviceAddedAt(client, client.deviceID)!.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
      );
      await recordDeviceAdded(client, now.add(const Duration(days: 1)));
      expect(client.writes, 1);
      client.accountData.clear();
      client.fail = true;
      await recordDeviceAdded(client, now);
      expect(deviceAddedAt(client, client.deviceID), isNull);
      final type = deviceAddedType(client.deviceID);
      for (final invalid in [
        -1,
        'today',
        now.add(const Duration(days: 1)).millisecondsSinceEpoch,
      ]) {
        client.accountData[type] = mx.BasicEvent(
          type: type,
          content: {'added_at': invalid},
        );
        expect(deviceAddedAt(client, client.deviceID), isNull);
      }
    },
  );

  test(
    'Group avatar preserves encryption, joined history and invitation permissions',
    () async {
      final client = MetadataClient();
      await MatrixProbe(client).createRoom(
        ['@friend:local'],
        name: 'Семья',
        avatar: Uri.parse('mxc://local/avatar'),
      );
      final creation = client.creation!;
      expect(creation[#name], 'Семья');
      expect(creation[#invite], ['@friend:local']);
      expect(creation[#powerLevelContentOverride], {
        'invite': 50,
        'kick': 50,
        'ban': 50,
      });
      final state = creation[#initialState] as List<mx.StateEvent>;
      expect(
        state
            .firstWhere((e) => e.type == mx.EventTypes.Encryption)
            .content['algorithm'],
        'm.megolm.v1.aes-sha2',
      );
      expect(
        state
            .firstWhere((e) => e.type == 'm.room.history_visibility')
            .content['history_visibility'],
        'joined',
      );
      expect(
        state
            .firstWhere((e) => e.type == mx.EventTypes.RoomAvatar)
            .content['url'],
        'mxc://local/avatar',
      );
    },
  );

  test(
    'Main-thread receipt marks the exact last message; own and other-thread receipts do not',
    () {
      final client = ListClient();
      final room = mx.Room(id: '!receipt:local', client: client);
      room.lastEvent = mx.Event.fromJson({
        'event_id': 'latest',
        'type': mx.EventTypes.Message,
        'sender': client.userID,
        'origin_server_ts': 1700000000000,
        'content': {'msgtype': mx.MessageTypes.Text, 'body': 'Привет'},
      }, room);
      expect(conversationDeliveryStatus(room)?.$1, Icons.done);
      final main = room.receiptState.mainThread =
          mx.LatestReceiptStateForTimeline.empty();
      main.otherUsers[client.userID] = mx.LatestReceiptStateData('latest', 0);
      expect(conversationDeliveryStatus(room)?.$1, Icons.done);
      room.receiptState.byThread = {
        'thread': mx.LatestReceiptStateForTimeline.empty()
          ..otherUsers['@friend:local'] = mx.LatestReceiptStateData(
            'latest',
            0,
          ),
      };
      expect(conversationDeliveryStatus(room)?.$1, Icons.done);
      main.otherUsers['@friend:local'] = mx.LatestReceiptStateData('latest', 0);
      expect(conversationDeliveryStatus(room)?.$1, Icons.done_all);
      main.otherUsers['@friend:local'] = mx.LatestReceiptStateData(
        'older',
        9999999999999,
      );
      expect(conversationDeliveryStatus(room)?.$1, Icons.done);
    },
  );

  testWidgets(
    'Reaction changes retain exact footer geometry, scrolling and actions',
    (tester) async {
      var reactions = <String, List<String>>{};
      late StateSetter update;
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, set) {
                  update = set;
                  return MessageMetadata(
                    time: '12:30',
                    status: '12:30 · прочитано',
                    read: true,
                    color: Colors.white,
                    reactions: reactions,
                    onReaction: (emoji) => chosen = emoji,
                  );
                },
              ),
            ),
          ),
        ),
      );
      final before = tester.getRect(find.byType(MessageMetadata));
      update(
        () => reactions = {
          for (final emoji in ['👍', '❤️', '😂', '😮', '🙏'])
            emoji: ['Анна', 'Борис'],
        },
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(MessageMetadata)), before);
      await tester.tap(find.text('👍 2'));
      expect(chosen, '👍');
      expect(find.byIcon(Icons.done_all), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Nested back preserves parent draft and cancels child result', (
    tester,
  ) async {
    final draft = TextEditingController();
    addTearDown(draft.dispose);
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const AppDialogTitle(child: Text('Родитель')),
                  content: TextField(controller: draft),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        result = await showAppDialog<String>(
                          context: context,
                          builder: (context) => const AlertDialog(
                            title: AppDialogTitle(child: Text('Вложенное')),
                          ),
                        );
                      },
                      child: const Text('Далее'),
                    ),
                  ],
                ),
              ),
              child: const Text('Открыть'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Не терять');
    await tester.tap(find.text('Далее'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(draft.text, 'Не терять');
    expect(find.text('Родитель'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'Group form shows friends immediately, filters locally and returns a validated selection',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(320, 568), const Size(1366, 768)]) {
        tester.view.physicalSize = size;
        GroupDraft? result;
        final client = ListClient();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.halo.theme,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showAppDialog<GroupDraft>(
                      context: context,
                      builder: (_) => PeoplePicker.group(
                        client: client,
                        allowedUsers: {
                          '@alice:local',
                          '@bob:local',
                          client.userID,
                        },
                      ),
                    );
                  },
                  child: const Text('Открыть'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsNWidgets(2));
        expect(find.text(client.userID), findsNothing);
        await tester.tap(find.widgetWithText(CheckboxListTile, 'alice'));
        await tester.pumpAndSettle();
        final selectedPerson = size.width < 600
            ? find.byType(InputChip)
            : find.ancestor(
                of: find.byTooltip('Убрать участника'),
                matching: find.byType(ListTile),
              );
        final selectedAvatar = find.descendant(
          of: selectedPerson,
          matching: find.byType(PersonAvatar),
        );
        expect(selectedAvatar, findsOneWidget);
        expect(
          tester.getSize(selectedAvatar).shortestSide,
          greaterThanOrEqualTo(24),
        );
        await tester.ensureVisible(find.text('Создать'));
        await tester.tap(find.text('Создать'));
        await tester.pumpAndSettle();
        expect(find.text('Введите название группы'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), '  Семья  ');
        final search = find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.labelText == 'Поиск среди контактов',
        );
        await tester.enterText(search, 'bob');
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsOneWidget);
        await tester.tap(find.widgetWithText(CheckboxListTile, 'bob'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Создать'));
        await tester.tap(find.text('Создать'));
        await tester.pumpAndSettle();
        expect(result?.name, 'Семья');
        expect(result?.users.toSet(), {'@alice:local', '@bob:local'});
        expect(result?.avatar, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets(
    'Group creation remains usable in landscape and with 200 percent text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final (size, scale) in [
        (const Size(844, 390), 1.0),
        (const Size(320, 568), 2.0),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppPalette.halo.theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showAppDialog<GroupDraft>(
                    context: context,
                    builder: (_) => PeoplePicker.group(
                      client: ListClient(),
                      allowedUsers: {'@alice:local', '@bob:local'},
                    ),
                  ),
                  child: const Text('Открыть'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Закрыть'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
  testWidgets('Reaction footer keeps enlarged text inside its reserved row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppPalette.halo.theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: MessageMetadata(
              time: '12:30',
              status: 'Прочитано',
              read: true,
              edited: true,
              color: Colors.white,
              reactions: {
                '👍': ['Анна', 'Борис'],
              },
              onReaction: (_) {},
            ),
          ),
        ),
      ),
    );
    final footer = tester.getRect(find.byType(MessageMetadata));
    final label = tester.getRect(find.text('👍 2'));
    expect(label.top, greaterThanOrEqualTo(footer.top));
    expect(label.bottom, lessThanOrEqualTo(footer.bottom));
    expect(tester.takeException(), isNull);
  });
}
