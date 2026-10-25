import 'app_motion.dart';
import 'dart:async';
import 'dart:math' as math;
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
      titlePadding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
      title: AppDialogTitle(child: Align(alignment: Alignment.centerRight, child: IconButton(tooltip: 'Свернуть звонок', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.expand_more)))),
      content: SizedBox(
        width: video || calls.screen != null ? 850 : 500,
        height: math.min(MediaQuery.sizeOf(context).height * .65, 560),
        child: LayoutBuilder(
          builder: (context, box) {
            final compact = video || box.maxHeight < 330;
            final name =
                room?.getLocalizedDisplayname() ??
                (video ? 'Видеозвонок' : 'Голосовой звонок');
            final incoming =
                current == null &&
                !calls.starting &&
                (direct != null || group != null);
            final avatar = CallAvatar(
              incoming: incoming,
              child: PersonAvatar(
                name: name,
                client: calls.client,
                url: room == null ? null : roomAvatar(room!),
                group: room?.isDirectChat == false,
                showPresence: false,
                size: compact ? 64 : 104,
              ),
            );
            final details = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                if (current != null || active != null && !calls.starting) ...[
                  const SizedBox(height: 8),
                  Semantics(
                    label: 'Время разговора',
                    child: Text(
                      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                  ),
                ],
                if (current != null) ...[
                  const SizedBox(height: 8),
                  CallQualityIndicator(quality: current.quality),
                ],
              ],
            );
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (compact)
                      Row(
                        children: [
                          avatar,
                          const SizedBox(width: 12),
                          Expanded(child: details),
                        ],
                      )
                    else ...[
                      avatar,
                      const SizedBox(height: 22),
                      details,
                    ],
                    if (current != null && calls.screen != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: ScreenPanel(controller: calls.screen!),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (video && current != null) ...[
                      DropdownButton<VideoQuality>(
                        value: current.videoQuality,
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
                      SizedBox(
                        height: calls.screen?.snapshot?.state == 'active'
                            ? 160
                            : math.max(120, box.maxHeight - 210),
                        child: CallVideoGrid(call: current),
                      ),
                    ] else if (room?.isDirectChat == false)
                      FutureBuilder<List<mx.User>>(
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
                          return Column(
                            children: [
                              if (people.isNotEmpty) const SizedBox(height: 20),
                              for (final user in people)
                                ListTile(
                                  leading: PersonAvatar(
                                    name: user.displayName ?? user.id,
                                    client: calls.client,
                                    url: user.avatarUrl,
                                    online: connected.contains(user.id),
                                    size: 36,
                                  ),
                                  title: Text(user.displayName ?? user.id),
                                  subtitle: Text(
                                    connected.contains(user.id)
                                        ? 'В звонке'
                                        : user.membership ==
                                              mx.Membership.invite
                                        ? 'Ещё не вступил в чат'
                                        : current == null && !calls.starting
                                        ? 'Не подключён'
                                        : 'Ждём подключения',
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                  ],
                ),
              ),
            );
          },
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
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => perform(() => calls.declineDirect(direct)),
                  icon: const Icon(Icons.call_end),
                  label: const Text('Отклонить'),
                ),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => perform(() => calls.acceptDirect(direct)),
                  icon: const Icon(Icons.call),
                  label: const Text('Принять'),
                ),
              ] else if (current == null &&
                  !calls.starting &&
                  group != null) ...[
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => perform(() => calls.decline(group)),
                  icon: const Icon(Icons.call_end),
                  label: const Text('Отклонить'),
                ),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => perform(
                          () => calls.start(group.room, invitation: group),
                        ),
                  icon: const Icon(Icons.call),
                  label: const Text('Принять'),
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

class CallQualityIndicator extends StatelessWidget {
  final CallQuality quality;
  const CallQualityIndicator({super.key, required this.quality});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final filled = switch (quality) {
      CallQuality.excellent => 5,
      CallQuality.good => 3,
      CallQuality.poor => 1,
      CallQuality.unknown || CallQuality.lost => 0,
    };
    final color = quality == CallQuality.poor || quality == CallQuality.lost
        ? colors.error
        : colors.primary;
    return Semantics(
      label: '${quality.label}, $filled из 5 делений',
      excludeSemantics: true,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        children: [
          SizedBox(
            height: 24,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 5; i++)
                  Container(
                    key: ValueKey('signal-$i-${i < filled}'),
                    width: 5,
                    height: 7 + i * 4,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: i < filled ? color : colors.outlineVariant,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
          Text(quality.label, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

class CallAvatar extends StatefulWidget {
  final bool incoming;
  final Widget child;
  const CallAvatar({super.key, required this.incoming, required this.child});
  @override
  State<CallAvatar> createState() => _CallAvatarState();
}

class _CallAvatarState extends State<CallAvatar>
    with SingleTickerProviderStateMixin {
  late final pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    animate();
  }

  @override
  void didUpdateWidget(CallAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    animate();
  }

  void animate() {
    if (widget.incoming && !MediaQuery.disableAnimationsOf(context)) {
      if (!pulse.isAnimating) pulse.repeat(reverse: true);
    } else {
      pulse.stop();
      pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: pulse,
    child: widget.child,
    builder: (context, child) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Theme.of(context).colorScheme.primary.withValues(
          alpha: widget.incoming ? .08 + pulse.value * .12 : .06,
        ),
        boxShadow: widget.incoming
            ? [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withValues(
                    alpha: .12 * (1 - pulse.value),
                  ),
                  spreadRadius: 5 + pulse.value * 12,
                ),
              ]
            : null,
      ),
      child: child,
    ),
  );

  @override
  void dispose() {
    pulse.dispose();
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
