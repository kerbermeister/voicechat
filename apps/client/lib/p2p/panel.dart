import 'flow.dart';
import 'file_icon.dart';
import '../person_identity.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../app_motion.dart';
import '../file_source.dart';
import '../file_drop.dart';
import '../people_picker.dart';
import '../user_action_error.dart';
import 'protocol.dart';
import 'service.dart';

String p2pSize(num bytes) {
  if (bytes >= 1000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(2).replaceAll('.', ',')} ГБ';
  }
  if (bytes >= 1000000) {
    return '${(bytes / 1000000).toStringAsFixed(1).replaceAll('.', ',')} МБ';
  }
  if (bytes >= 1000) {
    return '${(bytes / 1000).toStringAsFixed(1).replaceAll('.', ',')} КБ';
  }
  return '${bytes.round()} Б';
}

class P2pRouteWarning extends StatelessWidget {
  final P2pRoute route;
  final bool outgoing;
  const P2pRouteWarning({
    super.key,
    required this.route,
    required this.outgoing,
  });
  @override
  Widget build(BuildContext context) {
    if (route != P2pRoute.relay) {
      return Text(route == P2pRoute.direct ? 'Напрямую' : 'Определяем маршрут');
    }
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                outgoing
                    ? 'Прямое соединение не установлено. Файлы передаются через сервер-ретранслятор'
                    : 'Файлы поступают через сервер-ретранслятор',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class P2pFileProgress extends StatelessWidget {
  final P2pFile file;
  final int bytes;
  final bool verified;
  const P2pFileProgress({
    super.key,
    required this.file,
    required this.bytes,
    required this.verified,
  });
  @override
  Widget build(BuildContext context) {
    final value = file.size == 0 ? (verified ? 1.0 : 0.0) : bytes / file.size;
    final percent = p2pPercent(bytes, file.size, verified: verified);
    return Row(
      children: [
        Semantics(
          label: 'Прогресс файла ${file.name}',
          value: percent,
          child: ExcludeSemantics(
            child: SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: value),
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 250),
                    builder: (context, n, _) => CircularProgressIndicator(
                      constraints: const BoxConstraints.tightFor(
                        width: 52,
                        height: 52,
                      ),
                      value: n,
                      strokeWidth: 3,
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                    ),
                  ),
                  P2pFileIcon(
                    name: file.name,
                    mime: file.mime,
                    verified: verified,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(file.name, softWrap: true),
              Text(
                '${p2pSize(bytes)} / ${p2pSize(file.size)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (verified) const Text('Целостность проверена'),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          percent,
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

class P2pPanel extends StatefulWidget {
  final P2pService service;
  const P2pPanel({super.key, required this.service});
  @override
  State<P2pPanel> createState() => _P2pPanelState();
}

class _P2pPanelState extends State<P2pPanel> {
  P2pService get service => widget.service;
  List<PickedFile> files = [];
  List<String> peers = [];
  String? error;
  bool acting = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    service.addListener(changed);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => changed());
    unawaited(action(() => service.refreshPolicy()));
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> action(Future<dynamic> Function() fn) async {
    if (acting) return;
    setState(() {
      acting = true;
      error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is UserActionError
              ? e.message
              : 'Не удалось выполнить действие. Проверьте соединение и свободное место.',
        );
      }
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  Future<void> add(List<PickedFile> next) async {
    final policy = service.policy;
    if (policy == null ||
        files.length + next.length > policy.maxFiles ||
        next.any((f) => f.size > policy.maxBytes || f.size < 0)) {
      for (final f in next) {
        await f.release();
      }
      if (mounted) {
        setState(() => error = 'Превышен лимит размера или количества файлов.');
      }
      return;
    }
    if (!mounted) {
      for (final f in next) {
        await f.release();
      }
      return;
    }
    setState(() => files.addAll(next));
  }

  @override
  Widget build(BuildContext context) {
    final policy = service.policy;
    return PopScope(
      canPop: !service.preparing,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('P2P Share · Beta'),
          actions: [
            IconButton(
              tooltip: 'Отменить все активные передачи',
              onPressed: acting || !service.transfers.any((t) => t.active)
                  ? null
                  : () => action(() async {
                      for (final t
                          in service.transfers
                              .where((t) => t.active)
                              .toList()) {
                        await service.cancel(t);
                      }
                    }),
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          ],
        ),
        body: FileDrop(
          label: 'Отпустите файлы, чтобы подготовить передачу',
          enabled: !acting && !service.preparing && policy != null,
          onDrop: (list) => unawaited(add(list)),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Передача здесь и сейчас. Оба участника должны оставаться в приложении. После обрыва отправьте файлы заново. Сохраните полученные файлы до закрытия приложения.',
              ),
              const SizedBox(height: 12),
              if (policy != null)
                Text(
                  'До ${p2pSize(policy.maxBytes)} на файл · ${policy.maxFiles} файлов · ${policy.maxRecipients} получателей одновременно',
                ),
              if (policy == null)
                Text(service.warning ?? 'Получаем настройки сервера…'),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: acting || policy == null
                        ? null
                        : () => action(() async {
                            final selected = await showAppDialog<List<String>>(
                              context: context,
                              builder: (_) => PeoplePicker(
                                client: service.client,
                                multiple: true,
                                title: 'Получатели P2P',
                                allowedUsers: service.contacts.acceptedUsers,
                                initialUsers: peers,
                                maxSelected:
                                    (policy.maxRecipients -
                                            service.activeRecipients)
                                        .clamp(0, policy.maxRecipients),
                              ),
                            );
                            if (selected == null || !mounted) return;
                            if (selected.length + service.activeRecipients >
                                policy.maxRecipients) {
                              throw UserActionError(
                                'Слишком много одновременных получателей.',
                              );
                            }
                            setState(() => peers = selected);
                          }),
                    icon: const Icon(Icons.people_outline),
                    label: const Text('Выбрать получателей'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        acting ||
                            policy == null ||
                            files.length >= policy.maxFiles
                        ? null
                        : () => action(() async {
                            await add(
                              await chooseFiles(
                                maxCount: policy.maxFiles - files.length,
                                maxBytes: policy.maxBytes,
                              ),
                            );
                          }),
                    icon: const Icon(Icons.add),
                    label: const Text('Выбрать файлы'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                policy == null
                    ? 'Получатели: ${peers.length}'
                    : 'Получатели: ${peers.length} из ${policy.maxRecipients}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (service.activeRecipients > 0)
                Text(
                  'Уже получают другие передачи: ${service.activeRecipients}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              for (final peer in peers)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: PersonIdentity(client: service.client, userId: peer),
                  trailing: IconButton(
                    tooltip: 'Убрать получателя',
                    onPressed: acting
                        ? null
                        : () => setState(() => peers.remove(peer)),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                policy == null
                    ? 'Файлы: ${files.length}'
                    : 'Файлы: ${files.length} из ${policy.maxFiles}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (files.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Перетащите файлы сюда или нажмите «Выбрать файлы».',
                  ),
                ),
              for (final file in files)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox(
                    width: 52,
                    height: 52,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          constraints: const BoxConstraints.tightFor(
                            width: 52,
                            height: 52,
                          ),
                          value: 0,
                          strokeWidth: 3,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                        ),
                        P2pFileIcon(name: file.name, mime: file.mime),
                      ],
                    ),
                  ),
                  title: Text(file.name),
                  subtitle: Text(p2pSize(file.size)),
                  trailing: IconButton(
                    tooltip: 'Убрать файл',
                    onPressed: acting
                        ? null
                        : () {
                            setState(() => files.remove(file));
                            unawaited(file.release());
                          },
                    icon: const Icon(Icons.close),
                  ),
                ),
              if (files.isNotEmpty)
                Text(
                  'Всего: ${p2pSize(files.fold<int>(0, (sum, f) => sum + f.size))}',
                ),
              const SizedBox(height: 8),
              if (service.preparing) ...[
                LinearProgressIndicator(value: service.preparation),
                const Text('Подготавливаем и проверяем файлы…'),
                TextButton(
                  onPressed: service.cancelPreparation,
                  child: const Text('Отменить подготовку'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: acting || files.isEmpty || peers.isEmpty
                      ? null
                      : () => action(() async {
                          await service.send(List.of(peers), List.of(files));
                          if (mounted) {
                            setState(() {
                              files = [];
                              peers = [];
                            });
                          }
                        }),
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Отправить'),
                ),
              const SizedBox(height: 24),
              for (final transfer in service.transfers.reversed)
                _transfer(transfer),
            ],
          ),
        ),
      ),
    );
  }

  String date(DateTime value) {
    final local = value.toLocal();
    final locale = MaterialLocalizations.of(context);
    return '${locale.formatShortDate(local)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
  }

  Widget _transfer(P2pTransfer t) => Card(
    child: ExpansionTile(
      key: PageStorageKey('p2p-transfer:${t.id}'),
      initiallyExpanded: t.active,
      title: PersonIdentity(client: service.client, userId: t.peer),
      subtitle: Text(
        '${t.outgoing ? 'Отправка' : 'Получение'} · ${t.files.length} файл(ов) · ${t.label}\n'
        '${t.startedAt == null ? 'Создано' : 'Начало'}: ${date(t.startedAt ?? t.createdAt)}'
        '${t.finishedAt == null ? '' : '\nКонец: ${date(t.finishedAt!)}'}',
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.outgoing ? 'Кому' : 'От кого',
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 8),
              PersonIdentity(client: service.client, userId: t.peer),
              Text(t.label),
              P2pFlow(
                outgoing: t.outgoing,
                complete: t.state == P2pState.received,
                moving:
                    t.state == P2pState.transferring &&
                    t.speed.perSecond(DateTime.now().millisecondsSinceEpoch) >
                        0,
              ),
              if (t.error != null) Text(t.error!),
              if (t.route == P2pRoute.relay ||
                  t.state == P2pState.connecting ||
                  t.state == P2pState.transferring ||
                  t.state == P2pState.received) ...[
                const SizedBox(height: 8),
                P2pRouteWarning(route: t.route, outgoing: t.outgoing),
                Text(
                  'Скорость: ${p2pSize(t.active ? t.speed.perSecond(DateTime.now().millisecondsSinceEpoch) : 0)}/с',
                ),
              ],
              const SizedBox(height: 12),
              for (var i = 0; i < t.files.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    children: [
                      P2pFileProgress(
                        file: t.files[i],
                        bytes: t.bytes[i],
                        verified: t.verified[i],
                      ),
                      if (!t.outgoing && t.state == P2pState.received)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: t.exporting || acting
                                ? null
                                : () => action(() => service.save(t, i)),
                            icon: const Icon(Icons.save_alt),
                            label: Text(t.saved[i] ?? 'Сохранить файл'),
                          ),
                        ),
                    ],
                  ),
                ),
              if (!t.outgoing &&
                  t.state == P2pState.received &&
                  t.files.length > 1) ...[
                FilledButton.icon(
                  onPressed: t.exporting || acting
                      ? null
                      : () => action(() => service.saveAll(t)),
                  icon: const Icon(Icons.folder_zip_outlined),
                  label: Text(
                    t.exporting
                        ? 'Подготовка сохранения…'
                        : 'Сохранить все в ZIP',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!t.outgoing && t.state == P2pState.offered) ...[
                    FilledButton(
                      onPressed: acting
                          ? null
                          : () => action(() => service.accept(t)),
                      child: const Text('Принять'),
                    ),
                    TextButton(
                      onPressed: acting
                          ? null
                          : () =>
                                action(() => service.cancel(t, decline: true)),
                      child: const Text('Отклонить'),
                    ),
                  ] else if (t.active)
                    TextButton(
                      onPressed: () => action(() => service.cancel(t)),
                      child: const Text('Отменить передачу'),
                    ),
                  if (!t.active)
                    TextButton(
                      onPressed: t.exporting || acting
                          ? null
                          : () => action(() => service.remove(t)),
                      child: const Text('Удалить временные данные и карточку'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    timer?.cancel();
    service.removeListener(changed);
    for (final file in files) {
      unawaited(file.release());
    }
    super.dispose();
  }
}
