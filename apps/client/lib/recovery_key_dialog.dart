import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_motion.dart';
import 'file_io.dart';

const recoveryKeyFileName = 'voicechat-recovery-key.txt';

class RecoveryKeyDialog extends StatefulWidget {
  final String recoveryKey;
  const RecoveryKeyDialog({super.key, required this.recoveryKey});
  @override
  State<RecoveryKeyDialog> createState() => _RecoveryKeyDialogState();
}

class _RecoveryKeyDialogState extends State<RecoveryKeyDialog> {
  late final input = TextEditingController(text: widget.recoveryKey);
  bool busy = false;
  String? feedback;
  bool failed = false;

  Future<void> export({required bool copy}) async {
    setState(() {
      busy = true;
      feedback = null;
      failed = false;
    });
    try {
      if (copy) {
        await Clipboard.setData(ClipboardData(text: widget.recoveryKey));
        feedback = 'Ключ скопирован.';
      } else {
        final result = await saveTextFile(
          recoveryKeyFileName,
          widget.recoveryKey,
        );
        feedback = switch (result) {
          FileSaveResult.shared => 'Передано в меню сохранения.',
          FileSaveResult.saved => 'Файл сохранён.',
          FileSaveResult.downloadStarted =>
            'Файл передан браузеру. Проверьте загрузки.',
          FileSaveResult.cancelled => null,
        };
      }
    } catch (_) {
      failed = true;
      feedback = copy
          ? 'Не удалось скопировать ключ. Выделите его и скопируйте вручную.'
          : 'Не удалось сохранить файл. Повторите попытку или скопируйте ключ.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: const AppDialogTitle(child: Text('Сохраните ключ восстановления')),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Ключ понадобится, если вы потеряете все устройства. Храните его в безопасном месте и не отправляйте в чат. Файл содержит секретный ключ.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: input,
              readOnly: true,
              minLines: 3,
              maxLines: 5,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: 'Ключ восстановления',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => export(copy: true),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Скопировать ключ'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => export(copy: false),
                  icon: const Icon(Icons.save_alt_outlined),
                  label: const Text('Сохранить в файл'),
                ),
              ],
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(
                  semanticsLabel: 'Сохранение ключа',
                ),
              ),
            if (feedback != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    feedback!,
                    style: failed
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Я сохранил ключ'),
        ),
      ],
    ),
  );
}
