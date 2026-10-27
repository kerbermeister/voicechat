import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ResizableChatLayout extends StatefulWidget {
  final Widget Function(bool compact) sidebar;
  final Widget conversation;
  const ResizableChatLayout({
    super.key,
    required this.sidebar,
    required this.conversation,
  });
  @override
  State<ResizableChatLayout> createState() => _ResizableChatLayoutState();
}

class _ResizableChatLayoutState extends State<ResizableChatLayout> {
  static const preference = 'chat_sidebar_fraction';
  double? fraction;
  bool changed = false;
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((preferences) {
      final stored = preferences.get(preference);
      final value = stored is num ? stored.toDouble() : null;
      if (mounted && !changed && value != null && value.isFinite) {
        setState(() => fraction = value.clamp(.07, 1 / 3));
      }
    });
  }

  Future<void> save() async {
    final value = fraction;
    if (value == null) return;
    try {
      if (!await (await SharedPreferences.getInstance()).setDouble(
        preference,
        value,
      )) {
        throw StateError('Sidebar preference');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось сохранить ширину панели.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final current = (fraction ?? 300 / box.maxWidth).clamp(.07, 1 / 3);
      final width = box.maxWidth * current;
      void resize(double next) => setState(() {
        changed = true;
        fraction = next.clamp(.07, 1 / 3);
      });
      return Row(
        children: [
          SizedBox(width: width, child: widget.sidebar(width < 220)),
          Semantics(
            label: 'Ширина списка людей и групп',
            value: '${(current * 100).round()}%',
            increasedValue:
                '${((current + .02).clamp(.07, 1 / 3) * 100).round()}%',
            decreasedValue:
                '${((current - .02).clamp(.07, 1 / 3) * 100).round()}%',
            onIncrease: () {
              resize(current + .02);
              save();
            },
            onDecrease: () {
              resize(current - .02);
              save();
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => resize(
                  (fraction ?? current) + details.delta.dx / box.maxWidth,
                ),
                onHorizontalDragEnd: (_) => save(),
                onHorizontalDragCancel: save,
                child: SizedBox(
                  width: 8,
                  child: Center(
                    child: Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(vertical: 12),
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: widget.conversation),
        ],
      );
    },
  );
}
