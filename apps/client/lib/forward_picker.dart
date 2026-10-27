import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'app_motion.dart';
import 'conversation_list.dart';

class ForwardPicker extends StatelessWidget {
  final mx.Room currentRoom;
  const ForwardPicker({super.key, required this.currentRoom});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: AlertDialog(
      title: AppDialogTitle(child: const Text('Переслать сообщение')),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            const TabBar(
              tabs: [
                Tab(text: 'Люди'),
                Tab(text: 'Группы'),
              ],
            ),
            Expanded(
              child: StreamBuilder(
                stream: currentRoom.client.onPresenceChanged.stream,
                builder: (context, _) => TabBarView(
                  children: [
                    recipients(context, false),
                    recipients(context, true),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
      ],
    ),
  );

  Widget recipients(BuildContext context, bool groups) {
    final rooms = currentRoom.client.rooms
        .where(
          (room) =>
              room.membership == mx.Membership.join &&
              room.encrypted &&
              room.canSendDefaultMessages &&
              room.isDirectChat != groups,
        )
        .toList();
    if (rooms.isEmpty) {
      return Center(
        child: Text(groups ? 'Нет доступных групп' : 'Нет доступных людей'),
      );
    }
    return ListView.builder(
      itemCount: rooms.length,
      itemBuilder: (_, index) {
        final room = rooms[index];
        // ignore: deprecated_member_use
        final presence = room.client.presences[room.directChatMatrixID];
        return ListTile(
          key: ValueKey(room.id),
          leading: PersonAvatar(
            name: roomDisplayName(room),
            client: room.client,
            url: roomAvatar(room),
            group: groups,
            showPresence: presence != null,
            online: presence?.presence == mx.PresenceType.online,
          ),
          title: Text(roomDisplayName(room)),
          subtitle: Text(
            [
              if (!groups) roomPresence(room),
              if (room.id == currentRoom.id) 'Этот же чат',
            ].join(' · '),
          ),
          onTap: () => Navigator.pop(context, room),
        );
      },
    );
  }
}
