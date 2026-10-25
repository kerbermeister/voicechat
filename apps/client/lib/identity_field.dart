import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Public account/device identifiers only; copying never changes trust.
class IdentityField extends StatelessWidget {
  final String label;
  final String value;
  const IdentityField({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            String message;
            try {
              await Clipboard.setData(ClipboardData(text: value));
              message = '$label: скопировано';
            } catch (_) {
              message = 'Не удалось скопировать. Повторите попытку.';
            }
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(message)));
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                    Icon(Icons.copy_outlined, size: 18, color: colors.primary),
                  ],
                ),
                const SizedBox(height: 6),
                Text(value, style: const TextStyle(fontFamily: 'monospace')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
