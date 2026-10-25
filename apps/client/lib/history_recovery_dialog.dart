import 'app_motion.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'history_recovery.dart';
import 'user_action_error.dart';

class HistoryRecoveryDialog extends StatefulWidget {
  final HistoryRecovery owner;
  final Future<bool> Function(DeviceKeys) verify;
  const HistoryRecoveryDialog({
    super.key,
    required this.owner,
    required this.verify,
  });
  @override
  State<HistoryRecoveryDialog> createState() => _HistoryRecoveryDialogState();
}

class _HistoryRecoveryDialogState extends State<HistoryRecoveryDialog> {
  bool working = false;
  String? feedback;

  Future<void> act(Future<void> Function() action, String success) async {
    if (working) return;
    setState(() {
      working = true;
      feedback = null;
    });
    try {
      await action();
      if (mounted) setState(() => feedback = success);
    } catch (error) {
      if (mounted) {
        setState(
          () => feedback = error is UserActionError
              ? error.message
              : 'Не удалось выполнить действие. Проверьте соединение.',
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Widget requestCard(RoomKeyRequest request) => Semantics(
    container: true,
    explicitChildNodes: true,
    identifier: 'history-key-${request.request.sessionId}',
    label:
        'Ключ истории ${request.sender} / ${request.requestingDevice.deviceId}',
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(request.room.getLocalizedDisplayname()),
            Text('${request.sender} / ${request.requestingDevice.deviceId}'),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: working
                      ? null
                      : () => act(() async {
                          if (!await widget.verify(request.requestingDevice)) {
                            throw UserActionError(
                              'Сверка отменена. Ключи не переданы.',
                            );
                          }
                        }, 'Отпечаток совпал. Устройство проверено локально.'),
                  child: const Text('Сверить отпечаток'),
                ),
                TextButton(
                  onPressed: working
                      ? null
                      : () => act(
                          () => widget.owner.approve(request),
                          'Ключ истории передан зашифрованным сообщением.',
                        ),
                  child: const Text('Передать ключ'),
                ),
                TextButton(
                  onPressed: working
                      ? null
                      : () => widget.owner.dismiss(request),
                  child: const Text('Отклонить'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: AppDialogTitle(child: const Text('Запросы истории')),
    content: SizedBox(
      width: 500,
      height: 360,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (feedback != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(feedback!),
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.owner,
              builder: (_, _) => widget.owner.pending.isEmpty
                  ? const Center(child: Text('Ожидающих запросов нет'))
                  : ListView(
                      children: [
                        const Text(
                          'Ключ может открыть несколько старых сообщений этой комнаты. Передавайте его только после сверки отпечатка с экраном нужного устройства по независимому каналу.',
                        ),
                        ...widget.owner.pending.map(requestCard),
                      ],
                    ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: working ? null : () => Navigator.pop(context),
        child: const Text('Закрыть'),
      ),
    ],
  );
}
