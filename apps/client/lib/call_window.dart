import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;
import 'call_controller.dart';
import 'direct_call.dart';
import 'conversation_list.dart';
import 'call_quality.dart';
import 'call_video_grid.dart';
import 'call_event.dart';
import 'screen_panel.dart';

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
    final video = current?.video ?? direct?.video ?? group?.video ?? false;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      title: Row(
        children: [
          Expanded(
            child: Text(
              room?.getLocalizedDisplayname() ??
                  (video ? 'Видеозвонок' : 'Голосовой звонок'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Свернуть звонок',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.expand_more),
          ),
        ],
      ),
      content: SizedBox(
        width: video || calls.screen != null ? 850 : 500,
        height: video || calls.screen != null ? MediaQuery.sizeOf(context).height * .65 : 360,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
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
            if (current != null && calls.screen != null)
              ConstrainedBox(constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(child: ScreenPanel(controller: calls.screen!))),
            if (error != null) Text(error!),
            if (current != null)
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
                  ),
                  Text(
                    current.quality.label,
                    style: TextStyle(
                      color:
                          current.quality == CallQuality.poor ||
                              current.quality == CallQuality.lost
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                  if (video)
                    DropdownButton<VideoQuality>(
                      value: current.videoQuality,
                      hint: const Text('Качество видео'),
                      items: [
                        for (final quality in VideoQuality.values)
                          DropdownMenuItem(
                            value: quality,
                            child: Text(quality.label),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (value) {
                              if (value != null) {
                                perform(() => current.setVideoQuality(value));
                              }
                            },
                    ),
                ],
              ),
            if (video && current != null)
              Expanded(child: CallVideoGrid(call: current))
            else
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
                            online: present,
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
        SizedBox(
          width: (MediaQuery.sizeOf(context).width - 80)
              .clamp(100, 850)
              .toDouble(),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              if (current != null) ...[
                if (video) ...[
                  IconButton(
                    tooltip: current.cameraEnabled
                        ? 'Выключить камеру'
                        : 'Включить камеру',
                    onPressed: busy
                        ? null
                        : () => perform(
                            () => current.camera(!current.cameraEnabled),
                          ),
                    icon: Icon(
                      current.cameraEnabled
                          ? Icons.videocam
                          : Icons.videocam_off,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Переключить камеру',
                    onPressed: busy || !current.cameraEnabled
                        ? null
                        : () => perform(current.switchCamera),
                    icon: const Icon(Icons.cameraswitch_outlined),
                  ),
                ],
                IconButton(
                  tooltip: current.muted
                      ? 'Включить микрофон'
                      : 'Выключить микрофон',
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
              ] else if (current == null &&
                  !calls.starting &&
                  group != null) ...[
                TextButton(
                  onPressed: busy
                      ? null
                      : () => perform(() => calls.decline(group)),
                  child: const Text('Отклонить'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => perform(
                          () => calls.start(group.room, invitation: group),
                        ),
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
          ),
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
            isVideoCallEvent(event)
                ? Icons.videocam_outlined
                : event.content['action'] == 'invite' ||
                      event.type == mx.EventTypes.CallInvite
                ? Icons.call_outlined
                : Icons.call_end_outlined,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              '${callEventLabel(event)}${seconds == null ? '' : ' · ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}'}',
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
