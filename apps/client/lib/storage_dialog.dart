import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'storage_policy.dart';

class StorageDialog extends StatelessWidget {
  final StoragePolicy policy;
  const StorageDialog({super.key, required this.policy});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: policy,
    builder: (_, _) => AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Локальное хранилище'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Этот профиль: ${policy.usedBytes == null ? 'подсчёт…' : '${(policy.usedBytes! / 1048576).toStringAsFixed(1)} МиБ'}${kIsWeb ? ' (оценка данных)' : ''}',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: policy.limitMiB,
                decoration: const InputDecoration(
                  labelText: 'Лимит локальной копии',
                ),
                items:
                    {16, 64, 128, 256, 512, 1024, 2048, 4096, policy.limitMiB}
                        .toList()
                        .map(
                          (mib) => DropdownMenuItem(
                            value: mib,
                            child: Text('$mib МиБ'),
                          ),
                        )
                        .toList(),
                onChanged: policy.busy
                    ? null
                    : (value) async {
                        if (value == null) return;
                        try {
                          await policy.setLimit(value);
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Не удалось сохранить лимит.'),
                              ),
                            );
                          }
                        }
                      },
              ),
              const SizedBox(height: 16),
              const Text(
                'При достижении 90% удаляется старая локальная история закрытых чатов. Последние 30 событий каждого чата остаются; старые можно загрузить с сервера. Ключи, очередь и черновики не очищаются.',
              ),
              const SizedBox(height: 8),
              const Text(
                'Полученные вложения читаются потоково и автоматически на диск не копируются. Файлы, сохранённые вами в «Загрузки», в этот лимит не входят. Защищённые данные могут превышать лимит.',
              ),
              if (policy.busy)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              if (policy.warning != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(policy.warning!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: policy.busy ? null : policy.check,
          child: const Text('Проверить и очистить'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}
