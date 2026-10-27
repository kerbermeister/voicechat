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
  bool changed = false, hovering = false, dragging = false;
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((preferences) {
      final stored = preferences.get(preference);
      final value = stored is num ? stored.toDouble() : null;
      if (mounted && !changed && value != null && value.isFinite) {
        setState(() => fraction = value.clamp(.16, 1 / 3));
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
      final current = (fraction ?? 300 / box.maxWidth).clamp(.16, 1 / 3);
      final width = box.maxWidth * current;
      void resize(double next) => setState(() {
        changed = true;
        fraction = next.clamp(.16, 1 / 3);
      });
      return Row(
        children: [
          SizedBox(width: width, child: widget.sidebar(width < 220)),
          Semantics(
            label: 'Ширина списка людей и групп',
            value: '${(current * 100).round()}%',
            increasedValue:
                '${((current + .02).clamp(.16, 1 / 3) * 100).round()}%',
            decreasedValue:
                '${((current - .02).clamp(.16, 1 / 3) * 100).round()}%',
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
              onEnter: (_) => setState(() => hovering = true),
              onExit: (_) => setState(() => hovering = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => setState(() => dragging = true),
                onHorizontalDragUpdate: (details) => resize(
                  (fraction ?? current) + details.delta.dx / box.maxWidth,
                ),
                onHorizontalDragEnd: (_) {
                  setState(() => dragging = false);
                  save();
                },
                onHorizontalDragCancel: () {
                  setState(() => dragging = false);
                  save();
                },
                child: SizedBox(
                  width: 24,
                  child: ColoredBox(
                    color: hovering || dragging
                        ? Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: .10)
                        : Colors.transparent,
                    child: Center(
                      child: Container(
                        width: hovering || dragging ? 3 : 1,
                        margin: const EdgeInsets.symmetric(vertical: 12),
                        color: hovering || dragging
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                      ),
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
