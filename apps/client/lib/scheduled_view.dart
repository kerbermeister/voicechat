import 'app_motion.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'scheduled_messages.dart';

String scheduledTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} ${two(local.hour)}:${two(local.minute)}';
}

Future<DateTime?> chooseScheduledTime(
  BuildContext context,
  int maximumSeconds, {
  DateTime? initial,
}) async {
  final now = DateTime.now();
  final last = now.add(Duration(seconds: maximumSeconds));
  var chosen =
      initial ??
      now.add(
        Duration(seconds: maximumSeconds < 300 ? maximumSeconds ~/ 2 : 300),
      );
  if (chosen.isBefore(now) || chosen.isAfter(last)) {
    chosen = now.add(Duration(seconds: maximumSeconds ~/ 2));
  }
  String? error;
  return showAppDialog<DateTime>(
    context: context,
    animationStyle: appAnimationStyle(context),
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return AlertDialog(
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 24,
          ),
          title: AppDialogTitle(
            child: const Text(
              'Отложенное сообщение',
              textAlign: TextAlign.center,
            ),
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Выберите, когда опубликовать сообщение.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        colors.surfaceContainerHigh,
                        colors.surfaceContainerLowest,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: colors.outlineVariant.withValues(alpha: .6),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        scheduledTime(chosen).split(' ').first,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        TimeOfDay.fromDateTime(chosen).format(context),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          letterSpacing: -1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Время вашего устройства',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: const Text('Дата'),
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          cancelText: 'Назад',
                          builder: (context, child) =>
                              AppModalBackdrop(child: child!),
                          initialDate: chosen,
                          firstDate: now,
                          lastDate: last,
                        );
                        if (date != null && context.mounted) {
                          update(() {
                            chosen = DateTime(
                              date.year,
                              date.month,
                              date.day,
                              chosen.hour,
                              chosen.minute,
                            );
                            error = null;
                          });
                        }
                      },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.schedule),
                      label: const Text('Время'),
                      onPressed: () async {
                        final time = await showTimePicker(
                          context: context,
                          cancelText: 'Назад',
                          builder: (context, child) =>
                              AppModalBackdrop(child: child!),
                          initialTime: TimeOfDay.fromDateTime(chosen),
                          initialEntryMode: TimePickerEntryMode.input,
                        );
                        if (time != null && context.mounted) {
                          update(() {
                            chosen = DateTime(
                              chosen.year,
                              chosen.month,
                              chosen.day,
                              time.hour,
                              time.minute,
                            );
                            error = null;
                          });
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'До ${scheduledTime(last)}. После подтверждения сервером приложение можно закрыть.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.check_rounded),
              onPressed: () {
                try {
                  validateSchedule(chosen, maximumSeconds);
                  Navigator.pop(context, chosen);
                } catch (failure) {
                  update(() => error = '$failure');
                }
              },
              label: const Text('Применить'),
            ),
          ],
        );
      },
    ),
  );
}

class ScheduledView extends StatefulWidget {
  final ScheduledMessages service;
  final String roomId;
  final bool queueOnly;
  const ScheduledView({
    super.key,
    required this.service,
    required this.roomId,
    this.queueOnly = false,
  });
  @override
  State<ScheduledView> createState() => _ScheduledViewState();
}

class _ScheduledViewState extends State<ScheduledView> {
  List<Map<String, dynamic>>? jobs;
  String? error;
  bool loading = false;
  final previews = <String, Future<String>>{};
  Timer? timer;
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final data = await widget.service.list();
      if (mounted) {
        setState(() {
          jobs = data
              .where(
                (job) =>
                    job['room_id'] == widget.roomId &&
                    (!widget.queueOnly || scheduledInQueue(job)),
              )
              .toList();
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Не удалось обновить расписание. Повторите при подключении.',
        );
      }
    } finally {
      loading = false;
    }
  }

  Future<void> cancel(String id) async {
    try {
      await widget.service.cancel(id);
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> preview(String id) async {
    try {
      final text = await widget.service.preview(id);
      if (!mounted) return;
      await showAppDialog<void>(
        context: context,
        animationStyle: appAnimationStyle(context),
        builder: (context) => AlertDialog(
          title: AppDialogTitle(child: const Text('Содержимое сообщения')),
          content: SingleChildScrollView(
            child: Semantics(
              container: true,
              label: text,
              liveRegion: true,
              child: SelectableText(text),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть просмотр'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: AppDialogTitle(
      child: const Text(
        'Запланированные сообщения',
        textAlign: TextAlign.center,
      ),
    ),
    scrollable: true,
    content: SizedBox(
      width: 500,
      height: (MediaQuery.sizeOf(context).height * .42).clamp(100, 380),
      child: Column(
        children: [
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (jobs == null && error == null) const LinearProgressIndicator(),
          Expanded(
            child: jobs?.isEmpty == true
                ? const Center(
                    child: Text(
                      'В этом чате пока нет запланированных сообщений.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: jobs?.length ?? 0,
                    itemBuilder: (context, index) {
                      final job = jobs![index];
                      return Card(
                        child: ListTile(
                          onTap:
                              job['state'] == 'pending' ||
                                  job['state'] == 'failed' ||
                                  job['state'] == 'retry'
                              ? () => preview(job['id'] as String)
                              : null,
                          leading: Icon(
                            job['state'] == 'failed'
                                ? Icons.error_outline
                                : Icons.schedule,
                          ),
                          title: Text(
                            scheduledTime(
                              DateTime.fromMillisecondsSinceEpoch(
                                job['due'] as int,
                              ),
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(switch (job['state']) {
                                'pending' => 'Ожидает публикации',
                                'sent' => 'Опубликовано',
                                'cancelled' => 'Отменено',
                                'failed' => scheduledError(
                                  job['error'] as String?,
                                ),
                                'retry' =>
                                  'Повторяем после сбоя сервера. Зашифрованное сообщение сохранено.',
                                _ => 'Публикуется…',
                              }),
                              if (widget.queueOnly && job['state'] != 'sending')
                                FutureBuilder<String>(
                                  future: previews.putIfAbsent(
                                    job['id'] as String,
                                    () => widget.service.preview(
                                      job['id'] as String,
                                    ),
                                  ),
                                  builder: (context, snapshot) => Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      snapshot.data ??
                                          (snapshot.hasError
                                              ? 'Содержимое недоступно на этом устройстве'
                                              : 'Загрузка содержимого…'),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: ['pending', 'failed'].contains(job['state'])
                              ? IconButton(
                                  tooltip: 'Отменить запланированное сообщение',
                                  icon: const Icon(Icons.cancel_outlined),
                                  onPressed: () => cancel(job['id'] as String),
                                )
                              : null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actionsAlignment: MainAxisAlignment.center,
    actions: [
      TextButton(onPressed: refresh, child: const Text('Обновить')),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Закрыть'),
      ),
    ],
  );
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }
}

/// Counts server-acknowledged jobs; local transfers remain visible in the outbox.
class ScheduledQueueBar extends StatefulWidget {
  final ScheduledMessages service;
  final String roomId;
  final Listenable changes;
  const ScheduledQueueBar({
    super.key,
    required this.service,
    required this.roomId,
    required this.changes,
  });

  @override
  State<ScheduledQueueBar> createState() => _ScheduledQueueBarState();
}

class _ScheduledQueueBarState extends State<ScheduledQueueBar> {
  int? count;
  DateTime? nextDue;
  bool loading = false, stale = false;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(refresh);
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
  }

  @override
  void didUpdateWidget(ScheduledQueueBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes.removeListener(refresh);
      widget.changes.addListener(refresh);
    }
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final jobs = await widget.service.list();
      if (mounted) {
        setState(() {
          final queued = jobs
              .where(
                (job) =>
                    job['room_id'] == widget.roomId && scheduledInQueue(job),
              )
              .toList();
          count = queued.length;
          final dates =
              queued
                  .where((job) => job['state'] == 'pending')
                  .map((job) => job['due'])
                  .whereType<int>()
                  .where((due) => due >= DateTime.now().millisecondsSinceEpoch)
                  .toList()
                ..sort();
          nextDue = dates.isEmpty
              ? null
              : DateTime.fromMillisecondsSinceEpoch(dates.first);
          stale = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => stale = true);
    } finally {
      loading = false;
    }
  }

  Future<void> open() async {
    await showAppDialog<void>(
      context: context,
      animationStyle: appAnimationStyle(context),
      builder: (_) => ScheduledView(
        service: widget.service,
        roomId: widget.roomId,
        queueOnly: true,
      ),
    );
    if (mounted) await refresh();
  }

  @override
  Widget build(BuildContext context) {
    final hidden = (count == null || count == 0) && !stale;
    final colors = Theme.of(context).colorScheme;
    return AnimatedPanel(
      child: hidden
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Material(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  onTap: open,
                  dense: true,
                  minTileHeight: 48,
                  leading: const Icon(Icons.schedule_send_outlined),
                  title: Text(
                    count == null
                        ? 'Очередь расписания недоступна'
                        : 'Запланированные сообщения · $count',
                    style: TextStyle(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: stale
                      ? const Text('Нет обновления · нажмите, чтобы проверить')
                      : nextDue == null
                      ? null
                      : Text('Ближайшее: ${scheduledTime(nextDue!)}'),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ),
            ),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.changes.removeListener(refresh);
    super.dispose();
  }
}
