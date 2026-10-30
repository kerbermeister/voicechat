import 'dart:math' as math;
import 'package:flutter/material.dart';

class DeleteMessageDialog extends StatelessWidget {
  final bool allowAll;
  final int count;
  const DeleteMessageDialog({
    super.key,
    required this.allowAll,
    this.count = 1,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) {
      final colors = Theme.of(context).colorScheme;
      final labels = [
        'Отмена',
        'Удалить у меня',
        if (allowAll) 'Удалить у всех',
      ];
      final availableWidth = math.max(
        1.0,
        math.min(
          440.0,
          math.min(MediaQuery.sizeOf(context).width, viewport.maxWidth) -
              MediaQuery.viewInsetsOf(context).horizontal -
              64,
        ),
      );
      return AlertDialog(
        constraints: BoxConstraints(
          minWidth: availableWidth + 32,
          maxWidth: 520,
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        title: Text(
          count == 1
              ? 'Удалить сообщение?'
              : 'Удалить выбранные сообщения ($count)?',
        ),
        content: const Text(
          'Удаление у вас не меняет сообщения у других участников.',
        ),
        actions: [
          SizedBox(
            width: availableWidth,
            child: Builder(
              builder: (context) {
                final style = Theme.of(
                  context,
                ).textTheme.labelLarge!.copyWith(fontSize: 12, height: 1.1);
                final painter = TextPainter(
                  textDirection: Directionality.of(context),
                  textScaler: MediaQuery.textScalerOf(context),
                );
                var width = 136.0;
                for (final label in labels) {
                  painter
                    ..text = TextSpan(text: label, style: style)
                    ..layout();
                  width = math.max(width, painter.width.ceilToDouble() + 22);
                }
                final twoRows =
                    labels.length == 3 && width * 3 + 16 > availableWidth;
                width = math.min(
                  width,
                  (availableWidth - 8) / (twoRows ? 2 : labels.length),
                );
                final order = twoRows
                    ? [1, 2, 0]
                    : List.generate(labels.length, (i) => i);
                var height = 36.0;
                for (final label in labels) {
                  painter
                    ..text = TextSpan(text: label, style: style)
                    ..layout(maxWidth: math.max(1, width - 20));
                  height = math.max(height, painter.height + 8);
                }
                painter.dispose();
                return Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final i in order)
                      SizedBox(
                        width: width,
                        height: height,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: i == 0
                                ? const Color(0xff3265ac)
                                : i == 1
                                ? colors.errorContainer
                                : colors.error,
                            foregroundColor: i == 0
                                ? Colors.white
                                : i == 1
                                ? colors.onErrorContainer
                                : colors.onError,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            textStyle: style,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () => Navigator.pop(
                            context,
                            i == 0
                                ? null
                                : i == 1
                                ? 'mine'
                                : 'all',
                          ),
                          child: Text(labels[i], textAlign: TextAlign.center),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
