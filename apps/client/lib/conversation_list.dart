import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'typing_indicator.dart';
import 'avatar_image.dart';
import 'theme.dart';
import 'presence_tracker.dart';
import 'call_event.dart';

Uri? roomAvatar(mx.Room room) {
  final value = room.directChatMatrixID != null
      ? room
            .getState(mx.EventTypes.RoomMember, room.directChatMatrixID!)
            ?.content['avatar_url']
      : room.getState(mx.EventTypes.RoomAvatar)?.content['url'];
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  return uri?.scheme == 'mxc' ? uri : null;
}

String roomDisplayName(mx.Room room) {
  if (!room.isDirectChat) return room.getLocalizedDisplayname();
  final user = room.directChatMatrixID;
  final name = user == null
      ? null
      : room.getState(mx.EventTypes.RoomMember, user)?.content['displayname'];
  return name is String && name.isNotEmpty
      ? name
      : user?.split(':').first.replaceFirst('@', '') ?? 'Личный чат';
}

String roomPresence(mx.Room room) {
  if (!room.isDirectChat) {
    return 'Вступили: ${room.summary.mJoinedMemberCount ?? '—'} · приглашены: ${room.summary.mInvitedMemberCount ?? '—'}';
  }
  // Render the latest sync snapshot without network requests from build().
  // ignore: deprecated_member_use
  return presenceLabel(room.client.presences[room.directChatMatrixID]);
}

String lastMessage(mx.Room room) {
  if (room.membership == mx.Membership.invite) {
    return 'Приглашение · нажмите, чтобы войти';
  }
  final event = room.lastEvent;
  if (event == null) return 'Начните разговор';
  if (event.redacted) return 'Сообщение удалено';
  if (event.content.containsKey('dev.voicechat.ttl_seconds')) return 'Временное сообщение';
  if (event.type == mx.EventTypes.Encrypted) return 'Зашифрованное сообщение';
  if (event.type == mx.EventTypes.CallInvite) {
    return callEventLabel(event);
  }
  final text = switch (event.messageType) {
    'dev.voicechat.call' || 'dev.voicechat.call_summary' => event.body,
    mx.MessageTypes.Audio => '♫ Голосовое сообщение',
    'dev.voicechat.album' =>
      event.content['caption'] is String &&
              (event.content['caption'] as String).isNotEmpty
          ? '▧ ${event.content['caption']}'
          : '▧ Фотографии',
    mx.MessageTypes.Image => '▧ Изображение',
    _ => event.calcUnlocalizedBody(hideReply: true),
  };
  return event.senderId == room.client.userID ? 'Вы: $text' : text;
}

class PersonAvatar extends StatelessWidget {
  final String name;
  final mx.Client? client;
  final Uri? url;
  final bool group;
  final bool online;
  final double size;
  const PersonAvatar({
    super.key,
    required this.name,
    this.client,
    this.url,
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
            child: client != null && url != null
                ? ClipOval(
                    child: AvatarImage(
                      client: client!,
                      url: url!,
                      fallback: Icon(
                        group ? Icons.group_outlined : Icons.person_outline,
                      ),
                    ),
                  )
                : group
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
          if (!group)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 17,
                height: 17,
                decoration: BoxDecoration(
                  color: colors.surface,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  online ? Icons.circle : Icons.radio_button_unchecked,
                  size: 13,
                  color: online ? onlinePresenceColor(colors) : colors.outline,
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
  final VoidCallback? onInvitations;
  final VoidCallback? onSearch;
  final Uri? ownAvatar;
  final bool ownOnline;
  final VoidCallback? onProfile;
  final void Function(mx.Room, String)? onChatMenu;
  final int contactInvites;
  final Set<String> hiddenDirectRooms;
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
    this.onInvitations,
    this.onSearch,
    this.ownAvatar,
    this.ownOnline = false,
    this.onProfile,
    this.onChatMenu,
    this.contactInvites = 0,
    this.hiddenDirectRooms = const {},
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
                  (r.membership == mx.Membership.join) &&
                  (!r.isDirectChat ||
                      !widget.hiddenDirectRooms.contains(r.id)) &&
                  r.isDirectChat != groups &&
                  roomDisplayName(
                    r,
                  ).toLowerCase().contains(query.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => (b.lastEvent?.originServerTs ?? DateTime(1970)).compareTo(
              a.lastEvent?.originServerTs ?? DateTime(1970),
            ),
          );
    final invites =
        widget.contactInvites +
        widget.client.rooms
            .where(
              (r) => r.membership == mx.Membership.invite && !r.isDirectChat,
            )
            .length;
    int unread(bool groups) => widget.client.rooms
        .where(
          (r) =>
              r.membership == mx.Membership.join &&
              !widget.hiddenDirectRooms.contains(r.id) &&
              r.isDirectChat != groups &&
              (r.unreadMessageCount ?? r.notificationCount) > 0,
        )
        .length;
    Widget tab(String label, int count) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (count > 0) ...[
          const SizedBox(width: 6),
          Badge(label: Text('$count')),
        ],
      ],
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
                Color.lerp(colors.primary, colors.secondary, .3)!,
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
                  Expanded(
                    child: Text(
                      'VoiceChat',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Приглашения',
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onInvitations,
                    icon: Badge(
                      isLabelVisible: invites > 0,
                      label: Text('$invites'),
                      child: Icon(Icons.mail_outline, color: colors.onPrimary),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Поиск по чатам и сообщениям',
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onSearch,
                    icon: Icon(Icons.manage_search, color: colors.onPrimary),
                  ),
                  IconButton(
                    tooltip: 'Настройки',
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    padding: EdgeInsets.zero,
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
                  InkWell(
                    onTap: widget.onProfile,
                    borderRadius: BorderRadius.circular(24),
                    child: PersonAvatar(
                      name: name,
                      client: widget.client,
                      url: widget.ownAvatar,
                      online: widget.ownOnline,
                    ),
                  ),
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
                    segments: [
                      ButtonSegment(
                        value: false,
                        label: tab('Люди', unread(false)),
                        icon: const Icon(Icons.person_outline),
                      ),
                      ButtonSegment(
                        value: true,
                        label: tab('Группы', unread(true)),
                        icon: const Icon(Icons.group_outlined),
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
                    hintText: 'Поиск чатов по имени',
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
                              final messageCount =
                                  room.unreadMessageCount ??
                                  room.notificationCount;
                              final selected = room.id == widget.selected?.id;
                              final presence = roomPresence(room);
                              final name = roomDisplayName(room);
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
                                    trailing: widget.onChatMenu == null
                                        ? null
                                        : PopupMenuButton<String>(
                                            tooltip: 'Действия с чатом',
                                            onSelected: (action) =>
                                                widget.onChatMenu!(
                                                  room,
                                                  action,
                                                ),
                                            itemBuilder: (_) => [
                                              const PopupMenuItem(
                                                value: 'info',
                                                child: Text('Информация'),
                                              ),
                                              PopupMenuItem(
                                                value: 'mute',
                                                child: Text(
                                                  room.pushRuleState ==
                                                          mx
                                                              .PushRuleState
                                                              .dontNotify
                                                      ? 'Включить уведомления'
                                                      : 'Отключить уведомления',
                                                ),
                                              ),
                                              if (!room.isDirectChat)
                                                const PopupMenuItem(
                                                  value: 'leave',
                                                  child: Text(
                                                    'Покинуть группу',
                                                  ),
                                                ),
                                            ],
                                            icon: const Icon(Icons.more_horiz),
                                          ),
                                    leading: PersonAvatar(
                                      name: name,
                                      client: widget.client,
                                      url: roomAvatar(room),
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
                                            style: TextStyle(
                                              fontWeight: messageCount > 0
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        if (room.pushRuleState ==
                                            mx.PushRuleState.dontNotify)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 6,
                                            ),
                                            child: Tooltip(
                                              message: 'Уведомления отключены',
                                              child: Icon(
                                                Icons
                                                    .notifications_off_outlined,
                                                size: 16,
                                                color: colors.onSurfaceVariant,
                                                semanticLabel:
                                                    'Уведомления отключены',
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
                                                    ? onlinePresenceColor(
                                                        colors,
                                                      )
                                                    : colors.onSurfaceVariant,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: TypingIndicator(
                                                room: room,
                                                compact: true,
                                                fallback: Text(
                                                  lastMessage(room),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        fontWeight:
                                                            messageCount > 0
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                      ),
                                                ),
                                              ),
                                            ),
                                            if (messageCount > 0)
                                              Container(
                                                width: 28,
                                                height: 28,
                                                alignment: Alignment.center,
                                                decoration: BoxDecoration(
                                                  color: colors.primary,
                                                  shape: BoxShape.circle,
                                                ),
                                                child: Text(
                                                  messageCount > 999
                                                      ? '999+'
                                                      : '$messageCount',
                                                  style: TextStyle(
                                                    color: colors.onPrimary,
                                                    fontWeight: FontWeight.w700,
                                                    fontSize: messageCount > 99
                                                        ? 10
                                                        : 12,
                                                  ),
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
