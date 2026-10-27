import 'chat_scale.dart';
import 'package:flutter/gestures.dart';
import 'hidden_messages.dart';
import 'personal_room.dart';
import 'message_receipts.dart';
import 'app_motion.dart';
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
  if (isPersonalRoom(room)) return 'Личная комната · только вы';
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
  if (messageHidden(event)) return 'Сообщение удалено у вас';
  if (event.redacted) return 'Сообщение удалено';
  if (event.content.containsKey('dev.voicechat.ttl_seconds')) {
    return 'Временное сообщение';
  }
  if (event.type == mx.EventTypes.Encrypted) return 'Зашифрованное сообщение';
  if (event.type.startsWith('m.call.')) {
    return callEventLabel(event);
  }
  final text = switch (event.messageType) {
    'dev.voicechat.call' ||
    'dev.voicechat.call_summary' => callEventLabel(event),
    mx.MessageTypes.Audio => 'Голосовое сообщение',
    'dev.voicechat.file' when event.content['video_note'] == true =>
      'Видеосообщение',
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

/// Only an exact receipt can acknowledge the latest event without a loaded timeline.
/// Do not infer read state from receipt timestamps (they use a different clock).
(IconData, String)? conversationDeliveryStatus(mx.Room room) {
  final event = room.lastEvent;
  if (event == null || event.senderId != room.client.userID) return null;
  if (event.status == mx.EventStatus.error) {
    return (Icons.error_outline, 'Не отправлено');
  }
  if (event.status == mx.EventStatus.sending) {
    return (Icons.schedule, 'Отправляется');
  }
  final read =
      personalMessageIsRead(event) ||
      messageReadReceipts(
        room,
      ).any((receipt) => receipt.eventId == event.eventId);
  return read ? (Icons.done_all, 'Прочитано') : (Icons.done, 'Отправлено');
}

class PersonAvatar extends StatelessWidget {
  final String name;
  final mx.Client? client;
  final Uri? url;
  final bool group;
  final bool personal;
  final bool online;
  final double size;
  final bool showPresence;
  const PersonAvatar({
    super.key,
    required this.name,
    this.client,
    this.url,
    this.group = false,
    this.personal = false,
    this.online = false,
    this.size = 48,
    this.showPresence = true,
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
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(size * .32),
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
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
          ),
          if (personal)
            Positioned(
              right: 0,
              bottom: 0,
              child: Tooltip(
                message: 'Личная комната · только вы',
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.lock_outline,
                    size: 15,
                    color: colors.primary,
                    semanticLabel: 'Личная комната · только вы',
                  ),
                ),
              ),
            ),
          if (!personal && !group && showPresence)
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
  final int outgoingInvites;
  final Set<String> hiddenDirectRooms;
  final bool groups;
  final bool compact;
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
    this.outgoingInvites = 0,
    this.hiddenDirectRooms = const {},
    this.compact = false,
    required this.groups,
    required this.onTabChanged,
  });
  @override
  State<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends State<ConversationList> {
  bool get groups => widget.groups;
  String query = '';
  final peopleScroll = ScrollController(), groupsScroll = ScrollController();
  @override
  void dispose() {
    peopleScroll.dispose();
    groupsScroll.dispose();
    super.dispose();
  }

  List<PopupMenuEntry<String>> roomMenu(mx.Room room) {
    PopupMenuItem<String> item(String value, String label, IconData icon) =>
        PopupMenuItem(
          value: value,
          child: Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Flexible(child: Text(label)),
            ],
          ),
        );
    final muted = room.pushRuleState == mx.PushRuleState.dontNotify;
    return [
      item(
        'pin',
        room.isFavourite ? 'Открепить' : 'Закрепить сверху',
        room.isFavourite ? Icons.push_pin_outlined : Icons.push_pin,
      ),
      item('info', 'Информация', Icons.info_outline),
      item(
        'mute',
        muted ? 'Включить уведомления' : 'Отключить уведомления',
        muted
            ? Icons.notifications_active_outlined
            : Icons.notifications_off_outlined,
      ),
      if (!room.isDirectChat) item('leave', 'Покинуть группу', Icons.logout),
    ];
  }

  Future<void> openRoomMenu(mx.Room room, Offset point) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(point);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        local.dx,
        local.dy,
        overlay.size.width - local.dx,
        overlay.size.height - local.dy,
      ),
      items: roomMenu(room),
    );
    if (action != null && mounted) widget.onChatMenu?.call(room, action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
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
          ..sort((a, b) {
            if (a.isFavourite != b.isFavourite) return a.isFavourite ? -1 : 1;
            final time = (b.lastEvent?.originServerTs ?? DateTime(1970))
                .compareTo(a.lastEvent?.originServerTs ?? DateTime(1970));
            return time != 0 ? time : a.id.compareTo(b.id);
          });
    if (widget.compact) {
      Widget action(String label, IconData icon, VoidCallback? onPressed) =>
          IconButton(
            tooltip: label,
            icon: Icon(icon, size: 22),
            onPressed: onPressed,
          );
      return Column(
        children: [
          action(
            'Мой профиль',
            Icons.account_circle_outlined,
            widget.onProfile,
          ),
          action('Настройки', Icons.settings_outlined, widget.onSettings),
          action('Поиск', Icons.search, widget.onSearch),
          action(
            groups ? 'Группы · показать людей' : 'Люди · показать группы',
            groups ? Icons.groups_outlined : Icons.person_outline,
            () => widget.onTabChanged(!groups),
          ),
          Expanded(
            child: ListView.builder(
              controller: groups ? groupsScroll : peopleScroll,
              itemCount: rooms.length,
              itemBuilder: (context, index) {
                final room = rooms[index];
                final name = roomDisplayName(room);
                return Tooltip(
                  message: name,
                  child: GestureDetector(
                    onSecondaryTapDown: widget.onChatMenu == null
                        ? null
                        : (details) =>
                              openRoomMenu(room, details.globalPosition),
                    onLongPressStart: widget.onChatMenu == null
                        ? null
                        : (details) =>
                              openRoomMenu(room, details.globalPosition),
                    child: IconButton(
                      tooltip: name,
                      onPressed: () => widget.onSelect(room),
                      style: IconButton.styleFrom(
                        backgroundColor: room.id == widget.selected?.id
                            ? colors.primaryContainer
                            : null,
                      ),
                      icon: PersonAvatar(
                        name: name,
                        size: 34,
                        client: widget.client,
                        url: roomAvatar(room),
                        group: groups,
                        personal: isPersonalRoom(room),
                        online: roomPresence(room) == 'В сети',
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (widget.onInvitations != null)
            action('Приглашения', Icons.mail_outline, widget.onInvitations),
          action(
            groups ? 'Создать группу' : 'Новый разговор',
            Icons.add,
            groups ? widget.onNewGroup : widget.onNewPerson,
          ),
        ],
      );
    }
    final invites =
        widget.contactInvites +
        widget.outgoingInvites +
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
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (count > 0) ...[
          const SizedBox(width: 6),
          Badge(label: Text('$count')),
        ],
      ],
    );
    final name =
        widget.client.rooms
            .map(
              (room) => room
                  .getState(mx.EventTypes.RoomMember, widget.client.userID!)
                  ?.content['displayname'],
            )
            .whereType<String>()
            .where((name) => name.trim().isNotEmpty)
            .firstOrNull ??
        widget.client.userID!.split(':').first.substring(1);
    final content = Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Мой профиль',
                    padding: const EdgeInsets.all(4),
                    onPressed: widget.onProfile,
                    icon: PersonAvatar(
                      name: name,
                      client: widget.client,
                      url: widget.ownAvatar,
                      online: widget.ownOnline,
                      size: 48,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Image.asset(
                          'assets/branding/app-icon.png',
                          width: 20,
                          height: 20,
                          excludeFromSemantics: true,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            'VoiceChat',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: colors.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Поиск по чатам и сообщениям',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onSearch,
                    icon: Icon(Icons.manage_search, color: colors.onSurface),
                  ),
                  IconButton(
                    tooltip: 'Настройки',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onSettings,
                    icon: Icon(
                      Icons.settings_outlined,
                      color: colors.onSurface,
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
                top: Radius.circular(32),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
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
                        icon: largeText
                            ? null
                            : const Icon(Icons.person_outline),
                      ),
                      ButtonSegment(
                        value: true,
                        label: tab('Группы', unread(true)),
                        icon: largeText
                            ? null
                            : const Icon(Icons.group_outlined),
                      ),
                    ],
                    selected: {groups},
                    onSelectionChanged: (value) =>
                        widget.onTabChanged(value.single),
                  ),
                ),
                AnimatedPanel(
                  child: invites > 0
                      ? Material(
                          color: Colors.transparent,
                          child: ListTile(
                            key: const ValueKey('pending-invitations'),
                            dense: true,
                            leading: const Icon(Icons.mail_outline),
                            title: const Text('Приглашения'),
                            trailing: Badge(label: Text('$invites')),
                            onTap: widget.onInvitations,
                          ),
                        )
                      : null,
                ),
                const SizedBox(height: 8),
                TextField(
                  onChanged: (value) => setState(() => query = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded, size: 20),
                    hintText: 'Поиск чатов по имени',
                    isDense: true,
                  ),
                ),
                Divider(
                  height: 16,
                  thickness: 1,
                  color: colors.outlineVariant.withValues(alpha: .45),
                ),
                Expanded(
                  child: ClipRect(
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
                            primary: false,
                            controller: groups ? groupsScroll : peopleScroll,
                            itemCount: rooms.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
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
                              final voice =
                                  room.lastEvent?.messageType ==
                                  mx.MessageTypes.Audio;
                              final ownVoice =
                                  voice &&
                                  room.lastEvent?.senderId ==
                                      widget.client.userID;
                              final name = roomDisplayName(room);
                              final time = room.lastEvent?.originServerTs
                                  .toLocal();
                              return ChatScaled(
                                percent:
                                    ChatScaleScope.of(context)?.contacts ?? 80,
                                child: Listener(
                                  onPointerDown: widget.onChatMenu == null
                                      ? null
                                      : (details) {
                                          if (details.buttons ==
                                              kSecondaryMouseButton) {
                                            openRoomMenu(
                                              room,
                                              details.position,
                                            );
                                          }
                                        },
                                  child: AnimatedContainer(
                                    duration: motionDuration(context),
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
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                        minVerticalPadding: 6,
                                        horizontalTitleGap: 10,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        selected: selected,
                                        trailing: widget.onChatMenu == null
                                            ? null
                                            : PopupMenuButton<String>(
                                                popUpAnimationStyle:
                                                    appAnimationStyle(context),
                                                tooltip: 'Действия с чатом',
                                                onSelected: (action) =>
                                                    widget.onChatMenu!(
                                                      room,
                                                      action,
                                                    ),
                                                itemBuilder: (_) =>
                                                    roomMenu(room),
                                                icon: const Icon(
                                                  Icons.more_horiz,
                                                ),
                                              ),
                                        leading: Tooltip(
                                          message: presence,
                                          child: PersonAvatar(
                                            name: name,
                                            size: 38,
                                            client: widget.client,
                                            url: roomAvatar(room),
                                            group: groups,
                                            personal: isPersonalRoom(room),
                                            online: presence == 'В сети',
                                          ),
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
                                                      ? FontWeight.w600
                                                      : FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                            if (room.isFavourite)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 6,
                                                ),
                                                child: Icon(
                                                  Icons.push_pin,
                                                  size: 16,
                                                  color: colors.primary,
                                                  semanticLabel:
                                                      'Чат закреплён',
                                                ),
                                              ),
                                            if (room.pushRuleState ==
                                                mx.PushRuleState.dontNotify)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                  right: 6,
                                                ),
                                                child: Tooltip(
                                                  message:
                                                      'Уведомления отключены',
                                                  child: Icon(
                                                    Icons
                                                        .notifications_off_outlined,
                                                    size: 16,
                                                    color: colors.error,
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
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: colors
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                          ],
                                        ),
                                        subtitle: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const SizedBox(height: 1),
                                            Row(
                                              children: [
                                                if (conversationDeliveryStatus(
                                                      room,
                                                    )
                                                    case final status?) ...[
                                                  Tooltip(
                                                    message: status.$2,
                                                    child: Icon(
                                                      status.$1,
                                                      size: 16,
                                                      color: colors.primary,
                                                      semanticLabel: status.$2,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                ],
                                                Expanded(
                                                  child: TypingIndicator(
                                                    room: room,
                                                    compact: true,
                                                    fallback: Container(
                                                      padding: voice
                                                          ? const EdgeInsets.symmetric(
                                                              horizontal: 6,
                                                              vertical: 1,
                                                            )
                                                          : EdgeInsets.zero,
                                                      decoration: BoxDecoration(
                                                        color: voice
                                                            ? (ownVoice
                                                                  ? colors
                                                                        .primaryContainer
                                                                  : colors
                                                                        .tertiaryContainer)
                                                            : null,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              10,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        lastMessage(room),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: theme
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  messageCount >
                                                                      0
                                                                  ? FontWeight
                                                                        .w600
                                                                  : FontWeight
                                                                        .w400,
                                                              color: voice
                                                                  ? (ownVoice
                                                                        ? colors
                                                                              .onPrimaryContainer
                                                                        : colors
                                                                              .onTertiaryContainer)
                                                                  : colors
                                                                        .onSurfaceVariant,
                                                            ),
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
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize:
                                                            messageCount > 99
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
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 60),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      backgroundColor: colors.tertiaryContainer,
                      foregroundColor: colors.onTertiaryContainer,
                    ),
                    onPressed: groups ? widget.onNewGroup : widget.onNewPerson,
                    icon: Icon(
                      groups ? Icons.group_add_outlined : Icons.add_rounded,
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
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerLowest, colors.surface],
        ),
      ),
      child: content,
    );
  }
}
