import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Paint-only motion: the child keeps its layout, focus and semantics.
class AnimatedMessageBorder extends StatefulWidget {
  final Widget child;
  final bool active;
  final double radius, padding;
  const AnimatedMessageBorder({
    super.key,
    required this.child,
    this.active = true,
    this.radius = 26,
    this.padding = 6,
  });
  @override
  State<AnimatedMessageBorder> createState() => _AnimatedMessageBorderState();
}

class _AnimatedMessageBorderState extends State<AnimatedMessageBorder>
    with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    animate();
  }

  @override
  void didUpdateWidget(AnimatedMessageBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    animate();
  }

  void animate() {
    if (widget.active && !MediaQuery.disableAnimationsOf(context)) {
      if (!motion.isAnimating) motion.repeat();
    } else {
      motion.stop();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: motion,
    child: Padding(
      padding: EdgeInsets.all(widget.padding),
      child: widget.child,
    ),
    builder: (context, child) => CustomPaint(
      foregroundPainter: widget.active
          ? _Border(
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.tertiary,
              widget.radius,
              motion.value,
            )
          : null,
      child: child,
    ),
  );
  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }
}

class _Border extends CustomPainter {
  final Color first, second;
  final double radius, turn;
  _Border(this.first, this.second, this.radius, this.turn);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..shader = SweepGradient(
        colors: [
          first.withValues(alpha: .35),
          second,
          first,
          first.withValues(alpha: .35),
        ],
        transform: GradientRotation(turn * math.pi * 2),
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1.5), Radius.circular(radius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_Border old) =>
      first != old.first ||
      second != old.second ||
      turn != old.turn ||
      radius != old.radius;
}
