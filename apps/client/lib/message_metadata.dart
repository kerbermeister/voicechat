import 'package:flutter/material.dart';

/// A reserved footer keeps reaction updates from resizing the message bubble.
class MessageMetadata extends StatelessWidget {
  const MessageMetadata({
    super.key,
    required this.time,
    required this.status,
    required this.color,
    required this.reactions,
    required this.onReaction,
    this.read,
    this.edited = false,
    this.onCopy,
    this.saveButton,
  });

  static const minimumWidth = 190.0;

  static double rowHeight(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(12) * 1.5).clamp(
        24,
        double.infinity,
      );

  final String time, status;
  final Color color;
  final Map<String, List<String>> reactions;
  final ValueChanged<String> onReaction;
  final bool? read;
  final bool edited;
  final VoidCallback? onCopy;
  final Widget? saveButton;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: minimumWidth,
    height: rowHeight(context),
    child: LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          IconButton(
            tooltip: 'Скопировать сообщение',
            onPressed: onCopy,
            style: IconButton.styleFrom(
              minimumSize: const Size(24, 24),
              maximumSize: const Size(24, 24),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.copy_outlined, size: 10),
            color: color,
          ),
          if (saveButton != null) saveButton!,
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in reactions.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Tooltip(
                        message: entry.value.join('\n'),
                        child: TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: color,
                            backgroundColor: color.withValues(alpha: .12),
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            minimumSize: const Size(24, 24),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: Theme.of(
                              context,
                            ).textTheme.labelSmall?.copyWith(fontSize: 12),
                          ),
                          onPressed: () => onReaction(entry.key),
                          child: Text('${entry.key} ${entry.value.length}'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (box.maxWidth - 29 - (saveButton == null ? 0 : 24))
                  .clamp(0.0, double.infinity),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Tooltip(
                message: status,
                child: Semantics(
                  label: status,
                  excludeSemantics: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (edited)
                        Icon(Icons.edit_outlined, size: 12, color: color),
                      Text(time, style: TextStyle(fontSize: 11, color: color)),
                      if (read != null) ...[
                        const SizedBox(width: 3),
                        Icon(
                          read! ? Icons.done_all : Icons.done,
                          size: 14,
                          color: color,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
