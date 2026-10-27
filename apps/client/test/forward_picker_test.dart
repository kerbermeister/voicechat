import 'package:flutter/material.dart';
// ignore: implementation_imports
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'conversation_list_test.dart' show ListClient;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:voicechat_probe/conversation_list.dart';
import 'package:voicechat_probe/forward_picker.dart';

class PickerClient extends ListClient {
  @override
  CachedStreamController<mx.CachedPresence> get onPresenceChanged => events;
  final events = CachedStreamController<mx.CachedPresence>();
}

class RecipientRoom implements mx.Room {
  @override
  final roomAccountData = <String, mx.BasicEvent>{};
  @override
  final mx.Client client;
  @override
  final String id;
  @override
  final bool isDirectChat;
  @override
  final bool encrypted;
  RecipientRoom(
    this.client,
    this.id,
    this.isDirectChat, {
    this.encrypted = true,
  });
  @override
  mx.Membership get membership => mx.Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  @override
  String? get directChatMatrixID => isDirectChat ? '@alice:local' : null;
  @override
  mx.Event? getState(String type, [String stateKey = '']) => null;
  @override
  String getLocalizedDisplayname([mx.MatrixLocalizations? localizations]) =>
      'Команда';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Forward tabs separate recipients and return the chosen room', (
    tester,
  ) async {
    final client = PickerClient();
    final person = RecipientRoom(client, '!person:local', true);
    final group = RecipientRoom(client, '!group:local', false);
    client.rooms.addAll([
      person,
      group,
      RecipientRoom(client, '!unsafe:local', false, encrypted: false),
    ]);
    mx.Room? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showDialog<mx.Room>(
                  context: context,
                  builder: (_) => ForwardPicker(currentRoom: person),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('alice'), findsOneWidget);
    expect(find.text('Команда'), findsNothing);
    expect(find.textContaining('Статус недоступен'), findsOneWidget);
    expect(
      tester.widget<PersonAvatar>(find.byType(PersonAvatar)).showPresence,
      false,
    );
    for (final state in [mx.PresenceType.online, mx.PresenceType.offline]) {
      final presence = mx.CachedPresence.fromPresenceResponse(
        mx.GetPresenceResponse.fromJson({'presence': state.name}),
        '@alice:local',
      );
      client.presences['@alice:local'] = presence;
      client.events.add(presence);
      await tester.pumpAndSettle();
      final avatar = tester.widget<PersonAvatar>(find.byType(PersonAvatar));
      expect(avatar.showPresence, true);
      expect(avatar.online, state == mx.PresenceType.online);
      expect(
        find.textContaining(
          state == mx.PresenceType.online ? 'В сети' : 'Не в сети',
        ),
        findsOneWidget,
      );
    }
    await tester.tap(find.text('Группы'));
    await tester.pumpAndSettle();
    expect(find.text('alice'), findsNothing);
    expect(find.text('Команда'), findsOneWidget);
    expect(tester.widget<PersonAvatar>(find.byType(PersonAvatar)).group, true);
    await tester.tap(find.text('Команда'));
    await tester.pumpAndSettle();
    expect(selected, same(group));
  });
}
