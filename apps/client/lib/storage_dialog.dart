import 'app_motion.dart';
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
      title: AppDialogTitle(child: const Text('Локальное хранилище')),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StorageUsageChart(
                usedBytes: policy.usedBytes,
                limitMiB: policy.limitMiB,
              ),
              const SizedBox(height: 16),
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

class StorageUsageChart extends StatelessWidget {
  final int? usedBytes;
  final int limitMiB;
  const StorageUsageChart({
    super.key,
    required this.usedBytes,
    required this.limitMiB,
  });

  @override
  Widget build(BuildContext context) {
    final limit = limitMiB * 1048576;
    final ratio = usedBytes == null ? null : usedBytes! / limit;
    final remaining = usedBytes == null
        ? null
        : (limit - usedBytes!).clamp(0, limit);
    final colors = Theme.of(context).colorScheme;
    final exceeded = usedBytes != null && usedBytes! > limit;
    return Column(
      children: [
        Center(
          child: SizedBox(
            width: 144,
            height: 144,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: ratio?.clamp(0, 1),
                    strokeWidth: 12,
                    strokeCap: StrokeCap.round,
                    backgroundColor: colors.outlineVariant,
                    color: exceeded ? colors.error : colors.primary,
                    semanticsLabel: 'Занято от лимита локальной копии',
                    semanticsValue: ratio == null
                        ? 'Подсчёт'
                        : '${(ratio.clamp(0, 1) * 100).round()}%',
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ratio == null ? '…' : '${(ratio * 100).round()}%',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const Text('от лимита'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          remaining == null
              ? 'Подсчитываем объём…'
              : 'Занято: ${(usedBytes! / 1048576).toStringAsFixed(1)} МиБ · Осталось: ${(remaining / 1048576).toStringAsFixed(1)} МиБ',
          textAlign: TextAlign.center,
        ),
        if (exceeded)
          Text('Лимит превышен', style: TextStyle(color: colors.error)),
        const SizedBox(height: 6),
        Text(
          'Локальная копия профиля · лимит $limitMiB МиБ',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
    );
  }
}
