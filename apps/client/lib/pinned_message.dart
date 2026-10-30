import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'hidden_messages.dart';
import 'read_after.dart';
import 'temporary_message.dart';

bool canPinMessages(Room room) =>
    room.canChangeStateEvent(EventTypes.RoomPinnedEvents);

Future<void> togglePinnedMessage(Event event) async {
  if (!canPinMessages(event.room)) {
    throw StateError('Нет прав на закрепление сообщений.');
  }
  final ids = event.room.pinnedEventIds.toList();
  if (ids.contains(event.eventId)) {
    ids.remove(event.eventId);
  } else {
    if (event.redacted || messageExpired(event) || messageHidden(event)) {
      throw StateError('Сообщение недоступно.');
    }
    ids.add(event.eventId);
  }
  await event.room.setPinnedEvents(ids);
}

class PinnedMessageBar extends StatefulWidget {
  const PinnedMessageBar({
    super.key,
    required this.room,
    required this.timeline,
    required this.onJump,
    required this.onError,
  });
  final Room room;
  final Timeline timeline;
  final ValueChanged<String> onJump;
  final ValueChanged<String> onError;
  @override
  State<PinnedMessageBar> createState() => _PinnedMessageBarState();
}

class _PinnedMessageBarState extends State<PinnedMessageBar> {
  StreamSubscription<dynamic>? updates;
  Timer? deadline;
  late Future<Event?> pinned;
  @override
  void initState() {
    super.initState();
    ReadAfterState.of(widget.room.client).addListener(refresh);
    pinned = load();
    updates = widget.room.client.onSync.stream.listen((_) => refresh());
  }

  void refresh() {
    if (mounted) setState(() => pinned = load());
  }

  Future<Event?> load() async {
    final expired = <String>{};
    Event? first;
    DateTime? nearest;
    for (final id in widget.room.pinnedEventIds) {
      final event =
          widget.timeline.events
              .where((event) => event.eventId == id)
              .firstOrNull ??
          await widget.room.getEventById(id);
      if (!mounted) return null;
      if (event == null) continue;
      if (event.redacted ||
          emptyEncryptedEvent(event) ||
          messageExpired(event)) {
        expired.add(id);
        continue;
      }
      if (messageHidden(event)) continue;
      first ??= event;
      final expiry = messageExpiry(event);
      if (expiry != null && (nearest == null || expiry.isBefore(nearest))) {
        nearest = expiry;
      }
    }
    deadline?.cancel();
    if (nearest != null) {
      deadline = Timer(
        nearest.difference(DateTime.now()).isNegative
            ? Duration.zero
            : nearest.difference(DateTime.now()),
        refresh,
      );
    }
    // Filter immediately for everyone; persist cleanup when this account has pin rights.
    if (expired.isNotEmpty && canPinMessages(widget.room)) {
      await widget.room.setPinnedEvents(
        widget.room.pinnedEventIds
            .where((id) => !expired.contains(id))
            .toList(),
      );
    }
    return first;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Event?>(
    future: pinned,
    builder: (context, snapshot) {
      final event = snapshot.data;
      if (event == null ||
          event.redacted ||
          messageExpired(event) ||
          messageHidden(event)) {
        return const SizedBox.shrink();
      }
      final colors = Theme.of(context).colorScheme;
      return Material(
        color: colors.secondaryContainer,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.push_pin, color: colors.onSecondaryContainer),
          title: const Text('Закреплённое сообщение'),
          subtitle: Text(
            event.calcUnlocalizedBody(hideReply: true),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => widget.onJump(event.eventId),
          trailing: canPinMessages(widget.room)
              ? IconButton(
                  tooltip: 'Открепить сообщение',
                  icon: const Icon(Icons.close),
                  onPressed: () async {
                    try {
                      await togglePinnedMessage(event);
                      refresh();
                    } catch (_) {
                      widget.onError('Не удалось открепить сообщение.');
                    }
                  },
                )
              : null,
        ),
      );
    },
  );
  @override
  void dispose() {
    ReadAfterState.of(widget.room.client).removeListener(refresh);
    updates?.cancel();
    deadline?.cancel();
    super.dispose();
  }
}
