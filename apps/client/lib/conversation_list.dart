import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;

String roomPresence(mx.Room room) {
  if (!room.isDirectChat) {
    return '${room.summary.mJoinedMemberCount ?? 0} участников';
  }
  // Render the latest sync snapshot without network requests from build().
  // ignore: deprecated_member_use
  return switch (room.client.presences[room.directChatMatrixID]?.presence) {
    mx.PresenceType.online => 'В сети',
    mx.PresenceType.unavailable => 'Отошёл',
    mx.PresenceType.offline => 'Не в сети',
    _ => 'Статус неизвестен',
  };
}

String lastMessage(mx.Room room) {
  if (room.membership == mx.Membership.invite) {
    return 'Приглашение · нажмите, чтобы войти';
  }
  final event = room.lastEvent;
  if (event == null) return 'Начните разговор';
  if (event.redacted) return 'Сообщение удалено';
  if (event.type == mx.EventTypes.Encrypted) return 'Зашифрованное сообщение';
  final text = switch (event.messageType) {
    mx.MessageTypes.Audio => '♫ Голосовое сообщение',
    mx.MessageTypes.Image => '▧ Изображение',
    _ => event.calcUnlocalizedBody(hideReply: true),
  };
  return event.senderId == room.client.userID ? 'Вы: $text' : text;
}

class PersonAvatar extends StatelessWidget {
  final String name;
  final bool group;
  final bool online;
  final double size;
  const PersonAvatar({
    super.key,
    required this.name,
    this.group = false,
    this.online = false,
    this.size = 48,
  });
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = [
      colors.primaryContainer,
      colors.tertiaryContainer,
      colors.secondaryContainer,
    ][name.runes.fold(0, (a, b) => a + b) % 3];
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(size * .32),
            ),
            alignment: Alignment.center,
            child: group
                ? Icon(Icons.group_outlined, color: colors.onSurfaceVariant)
                : Text(
                    name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                    style: TextStyle(
                      fontSize: size * .4,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurface,
                    ),
                  ),
          ),
          if (online)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: const Color(0xFF39835F),
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ConversationList extends StatefulWidget {
  final mx.Client client;
  final mx.Room? selected;
  final ValueChanged<mx.Room> onSelect;
  final VoidCallback onNewPerson;
  final VoidCallback onNewGroup;
  final VoidCallback onSettings;
  final bool groups;
  final ValueChanged<bool> onTabChanged;
  const ConversationList({
    super.key,
    required this.client,
    this.selected,
    required this.onSelect,
    required this.onNewPerson,
    required this.onNewGroup,
    required this.onSettings,
    required this.groups,
    required this.onTabChanged,
  });
  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  bool get groups => widget.groups;
  String query = '';
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final rooms =
        widget.client.rooms
            .where(
              (r) =>
                  (r.membership == mx.Membership.join ||
                      r.membership == mx.Membership.invite) &&
                  r.isDirectChat != groups &&
                  r.getLocalizedDisplayname().toLowerCase().contains(
                    query.toLowerCase(),
                  ),
            )
            .toList()
          ..sort(
            (a, b) => (b.lastEvent?.originServerTs ?? DateTime(1970)).compareTo(
              a.lastEvent?.originServerTs ?? DateTime(1970),
            ),
          );
    final name = widget.client.userID!.split(':').first.substring(1);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 16, 30),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(colors.primary, Colors.white, .22)!,
                colors.primary,
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.graphic_eq_rounded, color: colors.onPrimary),
                  const SizedBox(width: 8),
                  Text(
                    'VoiceChat',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Настройки',
                    onPressed: widget.onSettings,
                    icon: Icon(
                      Icons.settings_outlined,
                      color: colors.onPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  PersonAvatar(name: name),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Привет, $name!',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: colors.onPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Хороший день для разговора',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            transform: Matrix4.translationValues(0, -16, 0),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: false,
                        label: Text('Люди'),
                        icon: Icon(Icons.person_outline),
                      ),
                      ButtonSegment(
                        value: true,
                        label: Text('Группы'),
                        icon: Icon(Icons.group_outlined),
                      ),
                    ],
                    selected: {groups},
                    onSelectionChanged: (value) =>
                        widget.onTabChanged(value.single),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  onChanged: (value) => setState(() => query = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded, size: 20),
                    hintText: 'Поиск в ваших чатах',
                    isDense: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 18,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      Text(
                        groups ? 'Ваши группы' : 'Недавние разговоры',
                        style: theme.textTheme.labelLarge,
                      ),
                      const Spacer(),
                      Text(
                        '${rooms.length}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    child: rooms.isEmpty
                        ? Center(
                            key: ValueKey('empty-$groups-$query'),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                query.isNotEmpty
                                    ? 'Ничего не найдено'
                                    : groups
                                    ? 'Соберите близких в одной группе'
                                    : 'Добавьте человека, чтобы начать разговор',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            key: ValueKey(groups),
                            itemCount: rooms.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 12,
                              color: colors.outlineVariant.withValues(
                                alpha: .45,
                              ),
                            ),
                            itemBuilder: (_, index) {
                              final room = rooms[index];
                              final selected = room.id == widget.selected?.id;
                              final presence = roomPresence(room);
                              final name = room.getLocalizedDisplayname();
                              final time = room.lastEvent?.originServerTs
                                  .toLocal();
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                decoration: BoxDecoration(
                                  color: selected
                                      ? colors.primaryContainer.withValues(
                                          alpha: .6,
                                        )
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    selected: selected,
                                    leading: PersonAvatar(
                                      name: name,
                                      group: groups,
                                      online: presence == 'В сети',
                                    ),
                                    title: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        if (time != null)
                                          Text(
                                            TimeOfDay.fromDateTime(
                                              time,
                                            ).format(context),
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(
                                                  color:
                                                      colors.onSurfaceVariant,
                                                ),
                                          ),
                                      ],
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 3),
                                        Text(
                                          presence,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                color: presence == 'В сети'
                                                    ? const Color(0xFF39835F)
                                                    : colors.onSurfaceVariant,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                lastMessage(room),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    theme.textTheme.bodySmall,
                                              ),
                                            ),
                                            if (room.notificationCount > 0)
                                              Badge(
                                                label: Text(
                                                  '${room.notificationCount}',
                                                ),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    onTap: () => widget.onSelect(room),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: groups ? widget.onNewGroup : widget.onNewPerson,
                    icon: Icon(
                      groups
                          ? Icons.group_add_outlined
                          : Icons.person_add_outlined,
                    ),
                    label: Text(groups ? 'Создать группу' : 'Найти человека'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
