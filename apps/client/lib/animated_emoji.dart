import 'dart:math' as math;
import 'emoji_style.dart';
import 'package:flutter/material.dart';

/// One ticker per open picker, never a ticker in delivered messages.
class EmojiMotion extends StatefulWidget {
  const EmojiMotion({super.key, required this.child});
  final Widget child;
  @override
  State<EmojiMotion> createState() => _EmojiMotionState();
}

class _EmojiMotionState extends State<EmojiMotion>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      motion.stop();
    } else {
      motion.repeat();
    }
  }

  @override
  Widget build(BuildContext context) =>
      _EmojiAnimation(animation: motion, child: widget.child);
  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }
}

class _EmojiAnimation extends InheritedWidget {
  const _EmojiAnimation({required this.animation, required super.child});
  final Animation<double> animation;
  @override
  bool updateShouldNotify(_EmojiAnimation oldWidget) =>
      animation != oldWidget.animation;
}

class AnimatedEmoji extends StatelessWidget {
  const AnimatedEmoji(this.emoji, {super.key, this.size = 30});
  final String emoji;
  final double size;
  @override
  Widget build(BuildContext context) {
    final text = Text(
      emoji,
      style: emojiStyle.copyWith(fontSize: size, height: 1.2),
    );
    final motion = context
        .dependOnInheritedWidgetOfExactType<_EmojiAnimation>()
        ?.animation;
    if (motion == null || MediaQuery.disableAnimationsOf(context)) return text;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: motion,
        child: text,
        builder: (_, child) {
          final wave = math.sin(motion.value * math.pi * 2);
          return Transform.rotate(
            angle: wave * .10,
            child: Transform.scale(scale: 1 + wave.abs() * .07, child: child),
          );
        },
      ),
    );
  }
}
