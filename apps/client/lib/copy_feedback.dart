import 'dart:async';
import 'package:flutter/material.dart';

/// Paints confirmation without changing the message's layout or hit targets.
class CopyFeedback extends StatefulWidget {
  final int pulse;
  final Widget child;
  final Color? color;
  const CopyFeedback({
    super.key,
    required this.pulse,
    required this.child,
    this.color,
  });
  @override
  State<CopyFeedback> createState() => _CopyFeedbackState();
}

class _CopyFeedbackState extends State<CopyFeedback>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  Timer? still;
  bool highlighted = false;
  @override
  void didUpdateWidget(CopyFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulse == widget.pulse) return;
    still?.cancel();
    animation.stop();
    highlighted = false;
    if (MediaQuery.disableAnimationsOf(context)) {
      highlighted = true;
      still = Timer(const Duration(milliseconds: 650), () {
        if (mounted) setState(() => highlighted = false);
      });
    } else {
      animation.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: widget.child,
    builder: (_, child) {
      final strength = highlighted
          ? 1.0
          : animation.isAnimating
          ? (animation.value < .08
                ? animation.value / .08
                : animation.value < .35
                ? 1.0
                : (1 - animation.value) / .65)
          : 0.0;
      return CustomPaint(
        foregroundPainter: _CopyBorder(
          widget.color ?? Theme.of(context).colorScheme.primary,
          strength,
        ),
        child: child,
      );
    },
  );
  @override
  void dispose() {
    still?.cancel();
    animation.dispose();
    super.dispose();
  }
}

class _CopyBorder extends CustomPainter {
  final Color color;
  final double strength;
  _CopyBorder(this.color, this.strength);
  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final rect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(2),
      const Radius.circular(18),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: strength * .5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_CopyBorder oldDelegate) =>
      oldDelegate.strength != strength || oldDelegate.color != color;
}
