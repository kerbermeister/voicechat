import 'personal_room.dart';
import 'app_motion.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'conversation_list.dart';
import 'presence_tracker.dart';

class RoomMembersDialog extends StatelessWidget {
  final mx.Room room;
  final List<mx.User> members;
  final Future<void> Function(String)? onAction;
  const RoomMembersDialog({
    super.key,
    required this.room,
    required this.members,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) => StreamBuilder<mx.CachedPresence>(
    stream: room.client.onPresenceChanged.stream,
    builder: (_, snapshot) => dialog(context),
  );

  void finish(BuildContext context, String? action) {
    if (action != null && onAction != null) {
      onAction!(action);
    } else {
      Navigator.pop(context, action);
    }
  }

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
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final user = users[i];
              // ignore: deprecated_member_use
              final presence = room.client.presences[user.id];
              return ListTile(
                dense: true,
                minVerticalPadding: 4,
                horizontalTitleGap: 10,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 2,
                ),
                leading: PersonAvatar(
                  name: user.displayName ?? user.id,
                  size: 36,
                  client: room.client,
                  url: user.avatarUrl,
                  online: presence?.presence == mx.PresenceType.online,
                ),
                onTap: () => finish(context, 'profile:${user.id}'),
                title: Text(
                  user.displayName ?? user.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
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
                        onPressed: () => finish(context, 'kick:${user.id}'),
                        icon: const Icon(Icons.person_remove_outlined),
                      )
                    : null,
              );
            },
          );
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: AppDialogTitle(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PersonAvatar(
                name: roomDisplayName(room),
                client: room.client,
                url: roomAvatar(room),
                personal: isPersonalRoom(room),
                group: true,
                showPresence: false,
                size: 96,
              ),
              const SizedBox(height: 12),
              Text(roomDisplayName(room), textAlign: TextAlign.center),
            ],
          ),
        ),
        content: SizedBox(
          width: 480,
          height: (MediaQuery.sizeOf(context).height * .42).clamp(100, 380),
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
        actionsAlignment: MainAxisAlignment.center,
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        actions: [
          Container(
            width: (MediaQuery.sizeOf(context).width - 56).clamp(17, 480),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Builder(
              builder: (context) {
                final trayWidth = (MediaQuery.sizeOf(context).width - 72).clamp(
                  1.0,
                  464.0,
                );
                final actions =
                    <
                      ({
                        String label,
                        IconData icon,
                        String? value,
                        bool danger,
                      })
                    >[
                      if (!room.isDirectChat &&
                          room.canChangeStateEvent(mx.EventTypes.RoomAvatar))
                        (
                          label: 'Аватар',
                          icon: Icons.add_a_photo_outlined,
                          value: 'avatar',
                          danger: false,
                        ),
                      if (!room.isDirectChat &&
                          !isPersonalRoom(room) &&
                          room.canInvite)
                        (
                          label: 'Пригласить',
                          icon: Icons.person_add_alt,
                          value: 'invite',
                          danger: false,
                        ),
                      if (!room.isDirectChat &&
                          room.canChangeStateEvent(mx.EventTypes.RoomName))
                        (
                          label: 'Название',
                          icon: Icons.edit_outlined,
                          value: 'rename',
                          danger: false,
                        ),
                      if (!room.isDirectChat)
                        (
                          label: 'Покинуть',
                          icon: Icons.logout,
                          value: 'leave',
                          danger: true,
                        ),
                      (
                        label: 'Закрыть',
                        icon: Icons.close,
                        value: null,
                        danger: false,
                      ),
                    ];
                final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
                final columns = (trayWidth / (60 * scale)).floor().clamp(
                  1,
                  actions.length,
                );
                return Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    for (final action in actions)
                      SizedBox(
                        width: trayWidth / columns,
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: action.danger
                                ? Theme.of(context).colorScheme.error
                                : null,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 0,
                              vertical: 10,
                            ),
                          ),
                          onPressed: () => finish(context, action.value),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(action.icon, size: 28),
                              const SizedBox(height: 6),
                              Text(
                                action.label,
                                textAlign: TextAlign.center,
                                style: Theme.of(
                                  context,
                                ).textTheme.labelSmall?.copyWith(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
