import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'conversation_list.dart';
import 'presence_tracker.dart';

class RoomMembersDialog extends StatelessWidget {
  final mx.Room room;
  final List<mx.User> members;
  const RoomMembersDialog({
    super.key,
    required this.room,
    required this.members,
  });
  @override
  Widget build(BuildContext context) => StreamBuilder<mx.CachedPresence>(
    stream: room.client.onPresenceChanged.stream,
    builder: (_, snapshot) => dialog(context),
  );

  Widget dialog(BuildContext context) {
    final joined = members
        .where((u) => u.membership == mx.Membership.join)
        .toList();
    final invited = members
        .where((u) => u.membership == mx.Membership.invite)
        .toList();
    Widget list(List<mx.User> users, String empty) => users.isEmpty
        ? Center(child: Text(empty))
        : ListView.separated(
            itemCount: users.length,
            separatorBuilder: (_, _) => const Divider(height: 16),
            itemBuilder: (_, i) {
              final user = users[i];
              // ignore: deprecated_member_use
              final presence = room.client.presences[user.id];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 8,
                ),
                leading: PersonAvatar(
                  name: user.displayName ?? user.id,
                  client: room.client,
                  url: user.avatarUrl,
                  online: presence?.presence == mx.PresenceType.online,
                ),
                onTap: () => Navigator.pop(context, 'profile:${user.id}'),
                title: Text(
                  user.displayName ?? user.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(user.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      '${presenceLabel(presence)}${user.membership == mx.Membership.invite
                          ? ' · Приглашён'
                          : user.id == room.client.userID
                          ? ' · Это вы'
                          : ''}',
                    ),
                  ],
                ),
                isThreeLine: true,
                trailing:
                    !room.isDirectChat &&
                        room.canKick &&
                        user.id != room.client.userID
                    ? IconButton(
                        tooltip: user.membership == mx.Membership.invite
                            ? 'Отменить приглашение'
                            : 'Исключить участника',
                        onPressed: () =>
                            Navigator.pop(context, 'kick:${user.id}'),
                        icon: const Icon(Icons.person_remove_outlined),
                      )
                    : null,
              );
            },
          );
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: Text(room.getLocalizedDisplayname()),
        content: SizedBox(
          width: 480,
          height: 380,
          child: Column(
            children: [
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                tabs: [
                  Tab(text: 'Вступили · ${joined.length}'),
                  Tab(text: 'Приглашены · ${invited.length}'),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TabBarView(
                  children: [
                    list(joined, 'Никто ещё не вступил'),
                    list(invited, 'Нет ожидающих приглашений'),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (!room.isDirectChat &&
              room.canChangeStateEvent(mx.EventTypes.RoomAvatar))
            TextButton.icon(
              onPressed: () => Navigator.pop(context, 'avatar'),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Аватар'),
            ),
          if (!room.isDirectChat && room.canInvite)
            TextButton.icon(
              onPressed: () => Navigator.pop(context, 'invite'),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Пригласить'),
            ),
          if (!room.isDirectChat &&
              room.canChangeStateEvent(mx.EventTypes.RoomName))
            TextButton(
              onPressed: () => Navigator.pop(context, 'rename'),
              child: const Text('Изменить название'),
            ),
          if (!room.isDirectChat)
            TextButton(
              onPressed: () => Navigator.pop(context, 'leave'),
              child: const Text('Покинуть чат'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}
