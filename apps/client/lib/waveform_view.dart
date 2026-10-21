import 'dart:math';
import 'package:flutter/material.dart';

class WaveformView extends StatelessWidget {
  final List<int> levels;
  final double progress;
  final Color? color;
  const WaveformView({
    super.key,
    required this.levels,
    this.progress = 0,
    this.color,
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 38,
    child: CustomPaint(
      size: const Size(double.infinity, 38),
      painter: _WavePainter(
        levels,
        progress,
        color ?? Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  final List<int> levels;
  final double progress;
  final Color color;
  _WavePainter(this.levels, this.progress, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final step = size.width / (levels.length + 1);
    final upper = Path()..moveTo(0, size.height / 2);
    final lower = Path()..moveTo(0, size.height / 2);
    for (var i = 0; i < levels.length; i++) {
      final amplitude =
          (sqrt(levels[i].clamp(0, 1024) / 1024) * (size.height / 2 - 2)).clamp(
            1.0,
            size.height / 2,
          );
      final x = step * (i + 1);
      upper.quadraticBezierTo(
        x - step / 2,
        size.height / 2 - amplitude,
        x,
        size.height / 2 - amplitude,
      );
      lower.quadraticBezierTo(
        x - step / 2,
        size.height / 2 + amplitude,
        x,
        size.height / 2 + amplitude,
      );
    }
    upper.lineTo(size.width, size.height / 2);
    lower.lineTo(size.width, size.height / 2);
    final paint = Paint()
      ..color = color.withValues(alpha: .45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(upper, paint);
    canvas.drawPath(lower, paint);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, 0, size.width * progress.clamp(0, 1), size.height),
    );
    paint.color = color;
    canvas.drawPath(upper, paint);
    canvas.drawPath(lower, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => true;
}
