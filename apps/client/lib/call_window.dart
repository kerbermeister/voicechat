import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'call_controller.dart';
import 'direct_call.dart';
import 'conversation_list.dart';

class CallWindow extends StatefulWidget {
  final CallController calls;
  final Future<void> Function() audioOutput;
  const CallWindow({super.key, required this.calls, required this.audioOutput});
  @override
  State<CallWindow> createState() => _CallWindowState();
}

class _CallWindowState extends State<CallWindow> {
  Timer? timer;
  bool busy = false;
  String? error;
  mx.Room? room;
  Future<List<mx.User>>? members;
  @override
  void initState() {
    super.initState();
    widget.calls.addListener(refresh);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Действие не удалось. Проверьте сеть и доступ.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final calls = widget.calls;
    final active = calls.active;
    final current = active != null && !active.isClosed ? active : null;
    final direct = calls.directInvitations.firstOrNull;
    final group = calls.invitations.values.firstOrNull;
    final nextRoom =
        current?.chat ??
        (calls.starting || calls.dialError != null
            ? calls.dialingRoom
            : null) ??
        direct?.chat ??
        group?.room ??
        active?.chat;
    if (room != nextRoom) {
      room = nextRoom;
      members = room?.requestParticipants();
    }
    final connected =
        current?.participants.map((p) => p.split('/').first).toSet() ??
        <String>{};
    if (current is DirectCall &&
        current.call.state != mx.CallState.kConnected) {
      connected.removeWhere((p) => p != calls.client.userID);
    }
    final duration = current?.duration ?? active?.duration ?? Duration.zero;
    final status =
        calls.dialError ??
        (calls.starting && current == null
            ? 'Вызываем…'
            : current?.connection ??
                  (direct != null || group != null
                      ? 'Входящий звонок'
                      : 'Звонок завершён'));
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(room?.getLocalizedDisplayname() ?? 'Голосовой звонок'),
          ),
          IconButton(
            tooltip: 'Свернуть звонок',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.expand_more),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 360,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  if (calls.starting || current != null && connected.length < 2)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.lock_outline),
                  const SizedBox(width: 14),
                  Expanded(child: Text(status)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
            ),
            if (error != null) Text(error!),
            Expanded(
              child: FutureBuilder<List<mx.User>>(
                future: members,
                builder: (_, snapshot) {
                  final people = (snapshot.data ?? <mx.User>[])
                      .where(
                        (u) => [
                          mx.Membership.join,
                          mx.Membership.invite,
                        ].contains(u.membership),
                      )
                      .toList();
                  return ListView.separated(
                    itemCount: people.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final user = people[i];
                      final present = connected.contains(user.id);
                      return ListTile(
                        leading: PersonAvatar(
                          name: user.displayName ?? user.id,
                          client: calls.client,
                          url: user.avatarUrl,
                        ),
                        title: Text(user.displayName ?? user.id),
                        subtitle: Text(
                          present
                              ? 'В звонке'
                              : user.membership == mx.Membership.invite
                              ? 'Ещё не вступил в чат'
                              : current == null && !calls.starting
                              ? 'Не подключён'
                              : 'Ждём подключения',
                        ),
                        trailing: present
                            ? const Icon(Icons.graphic_eq)
                            : const Icon(Icons.more_horiz),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (current != null) ...[
          IconButton(
            tooltip: current.muted ? 'Включить микрофон' : 'Выключить микрофон',
            onPressed: busy
                ? null
                : () => perform(() => current.mute(!current.muted)),
            icon: Icon(current.muted ? Icons.mic_off : Icons.mic),
          ),
          IconButton(
            tooltip: 'Аудиовыход',
            onPressed: busy ? null : () => perform(widget.audioOutput),
            icon: const Icon(Icons.speaker_outlined),
          ),
        ],
        if (current == null && !calls.starting && direct != null) ...[
          TextButton(
            onPressed: busy
                ? null
                : () => perform(() => calls.declineDirect(direct)),
            child: const Text('Отклонить'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () => perform(() => calls.acceptDirect(direct)),
            child: const Text('Принять'),
          ),
        ] else if (current == null && !calls.starting && group != null) ...[
          TextButton(
            onPressed: busy ? null : () => perform(() => calls.decline(group)),
            child: const Text('Отклонить'),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () =>
                      perform(() => calls.start(group.room, invitation: group)),
            child: const Text('Принять'),
          ),
        ] else if (current != null || calls.starting)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
            onPressed: busy ? null : () => perform(calls.end),
            icon: const Icon(Icons.call_end),
            label: const Text('Завершить'),
          )
        else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
      ],
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.calls.removeListener(refresh);
    super.dispose();
  }
}

class CallEventCard extends StatelessWidget {
  final mx.Event event;
  const CallEventCard({super.key, required this.event});
  @override
  Widget build(BuildContext context) {
    final duration = event.content['duration_ms'];
    final seconds = duration is int && duration > 0 && duration <= 86400000
        ? duration ~/ 1000
        : null;
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            event.content['action'] == 'invite'
                ? Icons.call_outlined
                : Icons.call_end_outlined,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              '${event.body}${seconds == null ? '' : ' · ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}'}',
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
