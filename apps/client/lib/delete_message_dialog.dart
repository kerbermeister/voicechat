import 'dart:math' as math;
import 'package:flutter/material.dart';

class DeleteMessageDialog extends StatelessWidget {
  final bool allowAll;
  const DeleteMessageDialog({super.key, required this.allowAll});
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labels = ['Отмена', 'Удалить у меня', if (allowAll) 'Удалить у всех'];
    return AlertDialog(
      title: const Text('Удалить сообщение?'),
      content: const Text(
        'Удаление у вас не меняет сообщения у других участников.',
      ),
      actions: [
        LayoutBuilder(
          builder: (context, constraints) {
            final style = Theme.of(
              context,
            ).textTheme.labelLarge!.copyWith(fontSize: 12, height: 1.25);
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
            width = math.min(width, constraints.maxWidth);
            var height = 36.0;
            for (final label in labels) {
              painter
                ..text = TextSpan(text: label, style: style)
                ..layout(maxWidth: math.max(1, width - 20));
              height = math.max(height, painter.height + 16);
            }
            painter.dispose();
            return Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < labels.length; i++)
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
                          vertical: 8,
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
      ],
    );
  }
}
