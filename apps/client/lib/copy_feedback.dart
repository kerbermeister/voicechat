import 'dart:async';
import 'package:flutter/material.dart';

/// Paints confirmation without changing the message's layout or hit targets.
class CopyFeedback extends StatefulWidget {
  final int pulse;
  final Widget child;
  const CopyFeedback({super.key, required this.pulse, required this.child});
  @override
  State<CopyFeedback> createState() => _CopyFeedbackState();
}

class _CopyFeedbackState extends State<CopyFeedback>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  Timer? still;
  bool highlighted = false;
  @override
  void didUpdateWidget(CopyFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulse == widget.pulse) return;
    still?.cancel();
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
          ? (animation.value < .2
                ? animation.value / .2
                : (1 - animation.value) / .8)
          : 0.0;
      return CustomPaint(
        foregroundPainter: _CopyBorder(
          Theme.of(context).colorScheme.primary,
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
        ..color = color.withValues(alpha: strength * .3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7,
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = color.withValues(alpha: strength)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CopyBorder oldDelegate) =>
      oldDelegate.strength != strength || oldDelegate.color != color;
}
