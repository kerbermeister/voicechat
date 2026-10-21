import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' as mx;

String typingLabel(mx.Room room, bool ownDraft) {
  final users = room.typingUsers;
  final others = users
      .where((u) => u.id != room.client.userID)
      .map((u) => u.displayName ?? u.id)
      .toList();
  final own = ownDraft || users.any((u) => u.id == room.client.userID);
  return [
    if (own) 'Вы печатаете',
    if (others.isNotEmpty)
      '${others.join(', ')} ${others.length > 1 ? 'печатают' : 'печатает'}',
  ].join(' · ');
}

class TypingIndicator extends StatefulWidget {
  final mx.Room room;
  final bool ownDraft;
  final bool compact;
  final Widget fallback;
  const TypingIndicator({
    super.key,
    required this.room,
    this.ownDraft = false,
    this.compact = false,
    this.fallback = const SizedBox.shrink(),
  });
  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> {
  Timer? timer;
  int phase = 0;
  @override
  void initState() {
    super.initState();
    updateTimer();
  }

  void updateTimer() {
    if (typingLabel(widget.room, widget.ownDraft).isEmpty) {
      timer?.cancel();
      timer = null;
      return;
    }
    timer ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (mounted) {
        setState(() => phase = (phase + 1) % 3);
        updateTimer();
      }
    });
  }

  @override
  void didUpdateWidget(TypingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    updateTimer();
  }

  @override
  Widget build(BuildContext context) {
    final label = typingLabel(widget.room, widget.ownDraft);
    final colors = Theme.of(context).colorScheme;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return AnimatedSwitcher(
      duration: duration,
      child: label.isEmpty
          ? widget.fallback
          : Container(
              key: const ValueKey('typing'),
              padding: widget.compact
                  ? EdgeInsets.zero
                  : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: widget.compact
                  ? null
                  : BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: 'Набор сообщения',
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < 3; i++)
                            AnimatedContainer(
                              duration: duration,
                              margin: EdgeInsets.only(
                                right: 3,
                                bottom:
                                    !MediaQuery.disableAnimationsOf(context) &&
                                        phase == i
                                    ? 4
                                    : 0,
                              ),
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                color: colors.primary.withValues(
                                  alpha: phase == i ? 1 : .35,
                                ),
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: colors.primary),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }
}
